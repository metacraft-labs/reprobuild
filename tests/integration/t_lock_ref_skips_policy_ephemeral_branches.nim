## A committed `repro.lock`'s advisory `ref` never names a branch that the
## branching policy deletes (Unified-Locking-And-Hooks.md §14.2; reprobuild-pm
## issue 2026-10-17 "committed lock ref can name a branch policy guarantees will
## be deleted").
##
## WHY. `ref` is a published branch containing the pinned commit, chosen in the
## order `agents`, `dev`, the checkout's own branch, the remote's default, then
## any other containing branch. On a stabilisation branch
## `agents-to-dev-<YYYY-MM-DD>` the own-branch candidate IS that branch, and the
## branching policy (metacraft-dev-guidelines `policies/branching-policy.md`
## §"Product Repository Branches") requires it to be deleted once it lands — so
## a refresh run there wrote a `ref` that names nothing a few days later
## (`runquota`'s self-record, `ref = "agents-to-dev-2026-10-12"`). Published is
## not durable: the policy-ephemeral class is skipped at every stage of the
## selection, and a recorded ephemeral `ref` is not kept as "still published".
##
## Fixture: `committed_lock_siblings_fixture.nim` — a real manifest workspace
## (app → lib-b → lib-c) of real git repositories cloned from real bare
## origins, refreshed with the built `repro`. Branches are real pushes to those
## origins, read back through real remote-tracking refs.
##
## Cases:
##   * (a) sibling on `agents-to-dev-<date>`, commit also on `origin/agents` →
##     `agents` (sanity: the preferred candidate already wins);
##   * (b) commit on `origin/agents-to-dev-<date>` and on a durable `release`
##     branch, sibling checked out on the stabilisation branch → `release`; and
##     the ROOT's self-record (the `runquota` incident) on the stabilisation
##     branch, with its commit also on the remote default `main` → `main`;
##   * (c) commit ONLY on `origin/agents-to-dev-<date>` → empty `ref`, whether
##     the sibling sits on that branch (own-branch candidate), on a local topic
##     branch (any-containing fallback), or the remote's default (`origin/HEAD`)
##     points at the stabilisation branch (remote-default candidate);
##   * (d) a lock that already records `ref = "agents-to-dev-<date>"` over an
##     UNMOVED revision has it replaced, by `repro lock refresh` and by the
##     managed `pre-commit` re-pin — both of which otherwise keep a recorded
##     `ref` that is still published; and `repro lock update --to` a revision
##     that stabilisation branch contains does not carry it over either.
##
## NO MOCKS. The hook file is written by hand rather than by
## `repro hooks ensure --vcs` so that it names the built binary by absolute
## path (a dev-shell `repro` on PATH cannot stand in for the one under test);
## its body is the managed body's dispatch line, as in
## `t_lock_refresh_never_moves_a_pin_backward.nim`.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support
import ./committed_lock_siblings_fixture

const
  Stabilisation = "agents-to-dev-2026-10-12"
  AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"

proc field(entry, key: string): string =
  let k = key & " = \""
  let at = entry.find(k)
  if at < 0: return "<absent>"
  let stop = entry.find('"', at + k.len)
  entry[at + k.len ..< stop]

proc pinOf(lockBody, name: string): string =
  field(depEntry(lockBody, name), "revision")

proc refOf(lockBody, name: string): string =
  field(depEntry(lockBody, name), "ref")

proc refresh(fx: SiblingFixture): tuple[code: int; output: string] =
  ## `repro lock refresh <app>`, with `REPRO_ALLOW_PIN_REGRESSION` cleared so a
  ## value exported in the suite's environment cannot leak in. Every case here
  ## moves lib-b forward, so no allowance is needed.
  runCmd(AllowEnv & "= " & q(fx.repro) & " lock refresh " & q(fx.app) &
    " 2>&1")

proc started(label: string): SiblingFixture =
  ## The baseline: a committed lock pinning every sibling at its published
  ## `main`.
  result = setupSiblingFixture(label)
  result.refreshAndPublishLock()

proc commitOn(fx: SiblingFixture; repo, localBranch: string;
    pushTo: openArray[string]): string =
  ## A new commit in `repo` on top of its current HEAD, made on `localBranch`
  ## (created there), pushed to each of `pushTo` on `origin` and fetched back,
  ## so the remote-tracking refs are what the writer reads. Returns its SHA.
  discard fx.git(repo, "checkout -q -B " & q(localBranch))
  writeFile(repo / "stabilise.txt", localBranch & " " & $pushTo.len & "\n")
  discard fx.git(repo, "add stabilise.txt")
  discard fx.git(repo, "commit -q -m stabilise")
  var specs: seq[string]
  for b in pushTo: specs.add(q("HEAD:" & b))
  if specs.len > 0:
    discard fx.git(repo, "push -q origin " & specs.join(" "))
  discard fx.git(repo, "fetch -q origin")
  fx.headOf(repo)

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

proc withRef(lockBody, revision, toRef: string): string =
  ## `lockBody` with the `ref` of the entry pinning `revision` set to `toRef`,
  ## whatever it recorded before — a hand-written stand-in for a lock
  ## refreshed by a writer that did not skip the ephemeral class.
  let pin = ", revision = \"" & revision & "\""
  let at = lockBody.find(pin)
  doAssert at >= 0, "no entry pinning " & revision & " in:\n" & lockBody
  let refAt = lockBody.rfind("ref = \"", 0, at)
  doAssert refAt >= 0 and lockBody.find('"', refAt + 7) + 1 == at,
    "the entry pinning " & revision & " has no `ref` before it:\n" & lockBody
  lockBody[0 ..< refAt] & "ref = \"" & toRef & "\"" & lockBody[at .. ^1]

suite "a committed lock's ref skips branches the policy deletes":

  test "t_a_stabilisation_checkout_still_prefers_agents":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let fx = started("ephemeral-ref-agents")
      defer: removeDir(fx.scratch)
      let libB = fx.ws / "lib-b"
      let next = fx.commitOn(libB, Stabilisation, [Stabilisation, "agents"])
      let r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      let body = readFile(fx.app / "repro.lock")
      checkpoint(body)
      check pinOf(body, "lib-b") == next
      check refOf(body, "lib-b") == "agents"

  test "t_a_stabilisation_checkout_records_a_durable_branch":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let fx = started("ephemeral-ref-durable")
      defer: removeDir(fx.scratch)
      let libB = fx.ws / "lib-b"
      # lib-b: the commit is on the stabilisation branch and on a durable
      # branch that is neither preferred nor the remote's default.
      let next = fx.commitOn(libB, Stabilisation, [Stabilisation, "release"])
      # app (the root, whose self-record is the `runquota` incident): checked
      # out on the stabilisation branch, whose tip is also on `main`.
      discard fx.git(fx.app, "checkout -q -b " & q(Stabilisation))
      discard fx.git(fx.app, "push -q origin " & q("HEAD:" & Stabilisation))
      discard fx.git(fx.app, "fetch -q origin")
      let r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      let body = readFile(fx.app / "repro.lock")
      checkpoint(body)
      check pinOf(body, "lib-b") == next
      check refOf(body, "lib-b") == "release"
      check refOf(body, ".") == "main"
      check ("\"" & Stabilisation & "\"") notin body

  test "t_a_commit_only_on_a_stabilisation_branch_records_no_ref":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let fx = started("ephemeral-ref-only")
      defer: removeDir(fx.scratch)
      let libB = fx.ws / "lib-b"
      let next = fx.commitOn(libB, Stabilisation, [Stabilisation])

      # Own-branch candidate: the checkout sits on the stabilisation branch.
      var r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      var body = readFile(fx.app / "repro.lock")
      checkpoint(body)
      check pinOf(body, "lib-b") == next
      check refOf(body, "lib-b") == ""

      # Any-containing fallback: the checkout is on a local topic branch, so
      # the only published branch containing the commit is found by the scan.
      discard fx.git(libB, "checkout -q -b local-topic")
      discard fx.git(fx.app, "checkout -q -- repro.lock")
      r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      body = readFile(fx.app / "repro.lock")
      checkpoint(body)
      check pinOf(body, "lib-b") == next
      check refOf(body, "lib-b") == ""

      # Remote-default candidate: `origin/HEAD` points at the stabilisation
      # branch (the default of a remote mid-promotion, or a stale `set-head`).
      discard fx.git(libB, "remote set-head origin " & q(Stabilisation))
      check fx.git(libB, "symbolic-ref --short refs/remotes/origin/HEAD").
        strip() == "origin/" & Stabilisation
      discard fx.git(fx.app, "checkout -q -- repro.lock")
      r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      body = readFile(fx.app / "repro.lock")
      checkpoint(body)
      check pinOf(body, "lib-b") == next
      check refOf(body, "lib-b") == ""
      check ("\"" & Stabilisation & "\"") notin body

  test "t_a_recorded_stabilisation_ref_is_replaced":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let fx = started("ephemeral-ref-recorded")
      defer: removeDir(fx.scratch)
      let libB = fx.ws / "lib-b"
      let lockPath = fx.app / "repro.lock"
      let next = fx.commitOn(libB, Stabilisation, [Stabilisation, "release"])
      var r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      check refOf(readFile(lockPath), "lib-b") == "release"
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app, "commit -q --no-verify -m pin-release")

      # A lock written before the fix: the same revision, the ephemeral ref.
      # `origin/agents-to-dev-…` still exists and still contains the revision,
      # so a writer that kept any still-published ref would keep this one.
      writeFile(lockPath,
        withRef(readFile(lockPath), next, Stabilisation))
      check refOf(readFile(lockPath), "lib-b") == Stabilisation

      # The explicit door: `repro lock refresh`.
      r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      var body = readFile(lockPath)
      checkpoint(body)
      check pinOf(body, "lib-b") == next
      check refOf(body, "lib-b") == "release"

      # The commit-time door: the managed `pre-commit` re-pin over an unmoved
      # revision.
      writeFile(lockPath, withRef(body, next, Stabilisation))
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app,
        "commit -q --no-verify --allow-empty -m hand-recorded-ephemeral")
      fx.installHook()
      let c = fx.tryCommit("repair-the-ephemeral-ref")
      checkpoint(c.output)
      check c.code == 0
      body = fx.git(fx.app, "show HEAD:repro.lock")
      checkpoint(body)
      check pinOf(body, "lib-b") == next
      check refOf(body, "lib-b") == "release"
      removeFile(fx.hookPath())

      # `repro lock update --to <rev>` moving a pin whose recorded ref is the
      # stabilisation branch, to a revision that branch contains: the ref is
      # not carried over as though it were a durable name for the target.
      let target = fx.commitOn(libB, Stabilisation, [Stabilisation])
      discard fx.git(libB, "checkout -q --detach " & next)
      writeFile(lockPath, withRef(readFile(lockPath), next, Stabilisation))
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app,
        "commit -q --no-verify --allow-empty -m before-update")
      let u = runCmd(AllowEnv & "= " & q(fx.repro) & " lock update lib-b " &
        "--to " & target & " 2>&1", fx.app)
      checkpoint(u.output)
      check u.code == 0
      body = readFile(lockPath)
      checkpoint(body)
      check pinOf(body, "lib-b") == target
      check refOf(body, "lib-b") == ""
