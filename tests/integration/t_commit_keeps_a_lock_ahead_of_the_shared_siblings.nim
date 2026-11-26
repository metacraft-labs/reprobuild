## A repository whose committed `repro.lock` is AHEAD of the sibling
## checkouts beside it can still commit: the managed `pre-commit` hook keeps
## the pins the lock carries instead of refusing the commit as "moving them
## backward" (Unified-Locking-And-Hooks.md §13.3, "What 'backward' is judged
## against").
##
## WHY. Several projects can share one workspace root, and then the sibling
## checkouts sit at whichever project last put them there. A repository whose
## own lock is legitimately newer than those checkouts sees every pin as
## "behind" its checkout. Backward is a property of the commit — it moves a
## pin to an older revision than the branch's lock already carries — not of a
## checkout. A checkout older than the pin leaves the hook nothing to advance
## to, and keeping the pin moves nothing. Refusing made such a repository
## uncommittable from the shared root ("would move N pinned siblings
## BACKWARD") although its commit changed no pin at all.
##
## Fixture: `committed_lock_siblings_fixture.nim` — a real manifest workspace
## of real git repositories cloned from real bare origins. app's recipe uses
## lib-b and lib-d (lib-b uses lib-c), so app's lock pins lib-b, lib-c and
## lib-d. The lock is brought to the newest published lib-b and lib-c by real
## commits, then lib-c's pin is replaced by a commit published from another
## clone that this workspace never fetched (a colleague's newer lock). Then
## the shared checkouts are moved BACK, as another project's pins would hold
## them: lib-b two commits behind its pin, lib-c lacking its pinned commit.
## A REAL `.git/hooks/pre-commit` issues the managed body's dispatch line with
## the built binary named by absolute path.
##
## Cases:
##   * a commit of an unrelated file succeeds; the committed `repro.lock` is
##     byte-identical to the parent's; one kept-pin notice per sibling is
##     printed (sibling, relation and distance, both revisions, the forward
##     command, and `REPRO_ALLOW_PIN_REGRESSION=<sibling> git commit --amend
##     --no-edit` for recording the checkout in the commit just made)
##     and logged as a `repro-lock kept-pin:` line; the forward command runs
##     and brings the checkout to the pin;
##   * in the same state, a sibling that IS ahead of its pin (lib-d) still
##     advances in the same commit while the others are kept;
##   * the deliberate course, run exactly as the notice printed it after a
##     plain commit kept the pin, amends that commit to record lib-b's older
##     revision (lib-c stays kept), announced and logged as an allowed
##     regression;
##   * the explicit door, `repro lock refresh`, still REFUSES (exit 4) for
##     the same behind sibling: it records the checkouts, so keeping the pin
##     there would record a state that does not match them.
##
## Falsifiability: at the base commit this change was written on, the first
## three cases fail — the hook refuses each commit with "this commit would
## move N pinned sibling revision(s) BACKWARD" and exits non-zero. The
## explicit-door case passes there and must keep passing.
##
## NO MOCKS. The one arrangement is writing the hook file by hand instead of
## `repro hooks ensure --vcs`, so a dev-shell `repro` on PATH cannot stand in
## for the binary under test.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support
import ./committed_lock_siblings_fixture

const AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"

proc courseFor(sibling: string): string =
  ## The deliberate course a kept-pin notice prints for ``sibling``.
  AllowEnv & "=" & sibling & " git commit --amend --no-edit"

proc installHook(fx: SiblingFixture) =
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

proc removeHook(fx: SiblingFixture) =
  let hook = fx.app / ".git" / "hooks" / "pre-commit"
  if fileExists(hook): removeFile(hook)

proc gitCmd(fx: SiblingFixture; repo, args: string; allow = ""): string =
  ## `REPRO_ALLOW_PIN_REGRESSION` is set explicitly (empty unless ``allow``),
  ## so an exported value in the suite's environment cannot leak into a case.
  AllowEnv & "=" & q(allow) & " " & q(fx.gitBin) & " -C " & q(repo) & " " &
    args

proc tryCommit(fx: SiblingFixture; label: string; allow = ""):
    tuple[code: int; output: string] =
  writeFile(fx.app / (label & ".txt"), label & "\n")
  discard fx.git(fx.app, "add " & q(label & ".txt"))
  runCmd(fx.gitCmd(fx.app, "commit -m " & q(label), allow))

proc preCommitLog(fx: SiblingFixture): string =
  let path = fx.ws / ".repro" / "build" / "reports" / "pre-commit-lock.log"
  if fileExists(path): readFile(path) else: ""

proc pinOf(lockBody, name: string): string =
  let entry = depEntry(lockBody, name)
  let key = "revision = \""
  let at = entry.find(key)
  if at < 0: return ""
  let stop = entry.find('"', at + key.len)
  entry[at + key.len ..< stop]

proc backticked(text: string): seq[string] =
  var i = 0
  while true:
    let open = text.find('`', i)
    if open < 0: break
    let close = text.find('`', open + 1)
    if close < 0: break
    result.add(text[open + 1 ..< close])
    i = close + 1

proc lineWith(text: string; needles: varargs[string]): string =
  for line in text.splitLines():
    var all = true
    for n in needles:
      if n notin line:
        all = false
        break
    if all: return line
  ""

type Shared = object
  fx: SiblingFixture
  libB, libC, libD: string
  pinnedB: string     ## lib-b's newest published commit: app's lock pins it
  observedB: string   ## lib-b's checkout, two commits behind the pin
  absentC: string     ## lib-c's pin: published elsewhere, never fetched here
  observedC: string   ## lib-c's checkout

proc startAheadOfTheSharedCheckouts(label: string): Shared =
  var fx = setupSiblingFixture(label)
  result.libB = fx.ws / "lib-b"
  result.libC = fx.ws / "lib-c"
  result.libD = fx.ws / "lib-d"
  fx.setAppUses(@["lib-b", "lib-d"])
  fx.refreshAndPublishLock()
  doAssert pinOf(readFile(fx.app / "repro.lock"), "lib-d").len > 0,
    "app's lock does not pin lib-d"
  doAssert pinOf(readFile(fx.app / "repro.lock"), "lib-c").len > 0,
    "app's lock does not pin lib-c"
  # app's own lock moves ahead: lib-b two commits newer, recorded by a real
  # commit through the hook.
  discard fx.advance("lib-b")
  result.pinnedB = fx.advance("lib-b")
  fx.installHook()
  let adopt = fx.tryCommit("adopt-newer-lib-b")
  doAssert adopt.code == 0, "the baseline commit failed:\n" & adopt.output
  doAssert pinOf(fx.git(fx.app, "show HEAD:repro.lock"), "lib-b") ==
    result.pinnedB
  # A colleague's newer lock pins a lib-c commit published from another clone,
  # which this workspace's lib-c never fetched.
  var origin = ""
  for (name, path) in fx.origins:
    if name == "lib-c": origin = path
  let side = fx.scratch / "side-lib-c"
  discard requireCmd(q(fx.gitBin) & " clone -q " & q(fileUrl(origin)) &
    " " & q(side))
  discard fx.git(side, "config user.email tester@example.invalid")
  discard fx.git(side, "config user.name \"Lock Tester\"")
  discard fx.git(side, "config commit.gpgsign false")
  writeFile(side / "elsewhere.txt", "published from another clone\n")
  discard fx.git(side, "add elsewhere.txt")
  discard fx.git(side, "commit -q -m elsewhere")
  discard fx.git(side, "push -q origin HEAD:main")
  result.absentC = fx.headOf(side)
  let lock = readFile(fx.app / "repro.lock")
  let entry = depEntry(lock, "lib-c")
  let oldC = pinOf(lock, "lib-c")
  writeFile(fx.app / "repro.lock",
    lock.replace(entry, entry.replace(oldC, result.absentC)))
  fx.removeHook()
  discard fx.git(fx.app, "add repro.lock")
  discard fx.git(fx.app, "commit -q -m " & q("a colleague's newer lock"))
  fx.installHook()
  # The shared root's checkouts sit at another project's (older) pins.
  discard fx.git(result.libB, "reset -q --hard HEAD~2")
  result.observedB = fx.headOf(result.libB)
  result.observedC = fx.headOf(result.libC)
  doAssert runCmd(q(fx.gitBin) & " -C " & q(result.libC) & " cat-file -e " &
    result.absentC & "^{commit}").code != 0
  result.fx = fx

suite "pre-commit keeps a lock that is ahead of the shared siblings":

  test "t_a_commit_against_older_shared_checkouts_keeps_every_pin":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startAheadOfTheSharedCheckouts("keeps-pins")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      let parentLock = fx.git(fx.app, "show HEAD:repro.lock")
      let headBefore = fx.headOf(fx.app)

      let c = fx.tryCommit("unrelated-work")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & fx.preCommitLog())
      check c.code == 0
      check "REFUSED" notin c.output
      check "BACKWARD" notin c.output
      check fx.git(fx.app, "rev-parse HEAD~1").strip() == headBefore
      check fx.git(fx.app, "show HEAD:repro.lock") == parentLock
      check readFile(fx.app / "repro.lock") == parentLock
      check fx.git(fx.app, "status --porcelain").strip().len == 0

      # One notice per kept sibling, naming everything the spec lists.
      let keptB = lineWith(c.output, "repro pre-commit: ",
        "repro.lock sibling 'lib-b'", "behind by 2 commit(s)")
      checkpoint("lib-b notice: " & keptB)
      check keptB.len > 0
      check s.pinnedB in keptB
      check s.observedB in keptB
      check "kept" in keptB
      check "commit proceeds" in keptB
      check ("`" & courseFor("lib-b") & "`") in keptB
      let keptC = lineWith(c.output, "repro pre-commit: ",
        "repro.lock sibling 'lib-c'", "pinned commit " & s.absentC &
        " not present in")
      checkpoint("lib-c notice: " & keptC)
      check keptC.len > 0
      check s.observedC in keptC
      check "fetch" in keptC
      check ("`" & courseFor("lib-c") & "`") in keptC
      let logged = fx.preCommitLog()
      check lineWith(logged, "repro-lock kept-pin:", "lib-b",
        s.pinnedB, s.observedB).len > 0
      check lineWith(logged, "repro-lock kept-pin:", "lib-c",
        s.absentC).len > 0
      check "refused-pin-regression" notin logged

      # The forward command runs where the notice is printed and brings the
      # checkout up to the pin.
      let forward = backticked(keptB)
      checkpoint("lib-b commands: " & $forward)
      check forward.len >= 2
      if forward.len >= 2:
        check "merge --ff-only" in forward[0]
        let ran = runCmd(forward[0], fx.app)
        checkpoint("ran `" & forward[0] & "`:\n" & ran.output)
        check ran.code == 0
        check fx.headOf(s.libB) == s.pinnedB

  test "t_an_ahead_sibling_still_advances_beside_kept_pins":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startAheadOfTheSharedCheckouts("ahead-beside-kept")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      let parentLock = fx.git(fx.app, "show HEAD:repro.lock")
      let nextD = fx.advance("lib-d")
      let c = fx.tryCommit("work-with-a-newer-lib-d")
      checkpoint(c.output)
      check c.code == 0
      let committed = fx.git(fx.app, "show HEAD:repro.lock")
      check pinOf(committed, "lib-d") == nextD
      check pinOf(committed, "lib-b") == s.pinnedB
      check pinOf(committed, "lib-c") == s.absentC
      check depEntry(committed, "lib-b") == depEntry(parentLock, "lib-b")
      check depEntry(committed, "lib-c") == depEntry(parentLock, "lib-c")
      check lineWith(c.output, "repro.lock sibling 'lib-b'",
        "behind by 2 commit(s)").len > 0
      check "REFUSED" notin c.output

  test "t_the_printed_course_records_the_older_checkout_in_that_commit":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startAheadOfTheSharedCheckouts("printed-course-records")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      let parentLock = fx.git(fx.app, "show HEAD:repro.lock")
      let headBefore = fx.headOf(fx.app)
      # A plain commit keeps the pins and prints the course…
      let c = fx.tryCommit("work-against-an-older-lib-b")
      checkpoint(c.output)
      check c.code == 0
      check fx.git(fx.app, "show HEAD:repro.lock") == parentLock
      let keptB = lineWith(c.output, "repro pre-commit: ",
        "repro.lock sibling 'lib-b'", "behind by 2 commit(s)")
      var course = ""
      for cmd in backticked(keptB):
        if cmd.startsWith(AllowEnv & "="): course = cmd
      checkpoint("printed course: " & course)
      check course == courseFor("lib-b")
      # …and that command, run exactly as printed where the notice was
      # printed, amends the commit just made to record lib-b's checkout.
      let amended = runCmd(course, fx.app)
      checkpoint(amended.output)
      checkpoint("pre-commit log:\n" & fx.preCommitLog())
      check amended.code == 0
      check fx.git(fx.app, "rev-parse HEAD~1").strip() == headBefore
      check fx.git(fx.app, "log -1 --format=%s").strip() ==
        "work-against-an-older-lib-b"
      let committed = fx.git(fx.app, "show HEAD:repro.lock")
      check pinOf(committed, "lib-b") == s.observedB
      check pinOf(committed, "lib-c") == s.absentC
      check depEntry(committed, "lib-c") == depEntry(parentLock, "lib-c")
      check fx.git(fx.app, "status --porcelain").strip().len == 0
      let announced = lineWith(amended.output, "allowed pin regression",
        "repro.lock sibling 'lib-b'")
      checkpoint("announced: " & announced)
      check ("from " & s.pinnedB & " to " & s.observedB) in announced
      check lineWith(fx.preCommitLog(), "allowed pin regression", "lib-b",
        "from " & s.pinnedB & " to " & s.observedB).len > 0
      # lib-c was not named, so it is still kept.
      check lineWith(amended.output, "repro.lock sibling 'lib-c'",
        "kept").len > 0

  test "t_the_explicit_door_still_refuses_the_same_regression":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var s = startAheadOfTheSharedCheckouts("door-still-refuses")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      let lockBefore = readFile(fx.app / "repro.lock")
      let r = runCmd(q(fx.repro) & " lock refresh " & q(fx.app))
      checkpoint(r.output)
      check r.code == 4
      check "REFUSED" in r.output
      check lineWith(r.output, "repro.lock sibling 'lib-b'",
        "behind by 2 commit(s)").len > 0
      check readFile(fx.app / "repro.lock") == lockBefore
