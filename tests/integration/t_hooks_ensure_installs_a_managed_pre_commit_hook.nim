## NF-2 (Unified-Locking-And-Hooks.md §13.1) — **`repro hooks ensure --vcs`
## installs a managed `pre-commit` hook, and a real commit through THAT hook
## refreshes and stages `flake.lock`**.
##
## §13.1 makes the update rule a property of the lock's BACKEND:
##
##   > | out-of-tree … | the **pre-push gate** … | writes and publishes |
##   > | in-tree (**committed-file**) | the **pre-commit hook**, as part of
##   >   forming the revision | **verifies only** |
##
## `flake.lock` is in-tree, so it takes the second row — and until NF-2 this
## repository had no managed `pre-commit` hook at all. Adding one to
## `VcsHookNames` is the change this case is about, and it has consequences the
## other NF-2 cases (which install the hook file directly) deliberately do not
## exercise:
##
##   * a `pre-commit` hook can **abort a commit**. Every other managed hook in
##     the set either runs after the fact or gates a push. So the ways this one
##     can fail all have to end in "the commit still happens";
##   * `.git/hooks/pre-commit` is the single most contested file in the
##     directory — the pre-commit framework owns it in this very repository,
##     driven from `git-hooks.nix`'s `shellHook` on every dev-shell entry. The
##     dispatcher's preserve-and-chain has to hold for it, and the preserved
##     hook has to keep being able to REFUSE.
##
## ## What is asserted
##
##   1. `hooks ensure --vcs` installs the `pre-commit` dispatcher plus its
##      `.repro-managed` body;
##   2. a pre-existing user `pre-commit` hook is preserved as
##      `pre-commit.repro-local` and STILL RUNS, first;
##   3. a real `git commit` through the managed hook refreshes `flake.lock`
##      from the moved sibling AND stages it, so the commit carries it;
##   4. the preserved user hook can still REFUSE: when it exits non-zero the
##      commit is rejected, and the managed body never runs;
##   5. a `repro` that does not speak the hook contract leaves the commit
##      ALONE — it announces the mismatch and exits 0. This is the fail-open
##      direction, and it is the one that matters: `PATH`'s `repro` on a
##      developer machine is routinely an older release, and a `pre-commit`
##      hook that failed closed on that would make the repository
##      uncommittable;
##   6. `ensure` is idempotent across a second run, and does not re-preserve
##      its own dispatcher as if it were a user hook;
##   7. `hooks uninstall --vcs` takes it back out.
##
## Test-double policy: NO mocks of the code under test. The `repro` binary,
## `git`, the hook installer and the commits are all real. Two SCRIPTS are
## written by this file and both are the test's own subject rather than stand-
## ins for anything: a user `pre-commit` hook (asserted to be preserved and
## chained — a real one would be some project's own script, and the dispatcher
## cannot tell the difference), and, for assertion (5), a two-line shell stub
## on `REPROBUILD_REPRO` that answers `--version` and fails the contract probe.
## The stub IS the condition under test — "the resolved `repro` does not
## generate this hook" — and using a genuine older release instead would pin
## the case to whichever release happened to be installed.

import std/[os, strutils, unittest]

import nf2_flake_lock_fixture

const UserHookMarker = "user-pre-commit-ran.txt"

proc writeUserPreCommitHook(fx: Nf2Fixture; exitCode: int) =
  ## A user's own `pre-commit` hook: it records that it ran, and exits with the
  ## status it was given so its power to REFUSE can be asserted too.
  let path = fx.app / ".git" / "hooks" / "pre-commit"
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "echo ran >> " & q(fx.scratch / UserHookMarker) & "\n" &
    "exit " & $exitCode & "\n")
  var perms = getFilePermissions(path)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, perms)

proc userHookRuns(fx: Nf2Fixture): int =
  let path = fx.scratch / UserHookMarker
  if not fileExists(path): return 0
  for line in readFile(path).splitLines():
    if line.strip().len > 0: inc result

suite "NF-2: hooks ensure installs a managed pre-commit hook":

  test "t_hooks_ensure_installs_a_managed_pre_commit_hook":
    if not nf2Prerequisites(
        "t_hooks_ensure_installs_a_managed_pre_commit_hook"):
      skip()
    else:
      let fx = setupNf2Fixture("ensure-pre-commit")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # Take the fixture's own directly-written hook back out: this case is
      # about what the INSTALLER puts there.
      removePreCommitDispatch(fx)
      writeUserPreCommitHook(fx, exitCode = 0)

      let hooksDir = fx.app / ".git" / "hooks"
      let ensured = run(q(fx.repro) & " hooks ensure --vcs " & q(fx.app),
        cwd = fx.app)
      if ensured.code != 0:
        checkpoint("`repro hooks ensure --vcs` output:\n" & ensured.output)
      check ensured.code == 0

      # ---- (1) the hook is on disk. ---------------------------------------
      # The dispatcher and the managed body are separate files with separate
      # jobs, and both are named: the dispatcher chains a preserved user hook
      # and then the managed body; the managed body is the one that resolves
      # `repro` and issues the dispatch. Asserting only the first would pass
      # for an install that never wrote the second.
      check fileExists(hooksDir / "pre-commit")
      check fileExists(hooksDir / "pre-commit.repro-managed")
      check readFile(hooksDir / "pre-commit").contains(
        "Reprobuild-managed pre-commit logic")
      check readFile(hooksDir / "pre-commit.repro-managed").contains(
        "hooks dispatch pre-commit")
      # The JSON `hooks-report.json` is a WORKSPACE-mode artifact; this
      # fixture's workspace resolves through a committed lock, which takes the
      # single-repo path (it prints the idempotent activation line `.envrc`
      # consumes and writes no report). That the report enumerates the new
      # hook is asserted where the report exists —
      # `t_workspace_hooks_ensure_is_idempotent_across_three_runs`, whose
      # per-repo hook count and hook-name list both now include `pre-commit`.
      check ensured.output.contains("repro hooks: VCS hooks ensure")

      # ---- (2) the user's hook is preserved and still runs. ---------------
      check fileExists(hooksDir / "pre-commit.repro-local")
      check readFile(hooksDir / "pre-commit.repro-local").contains(
        UserHookMarker)

      # The managed body resolves `repro` from `REPROBUILD_REPRO`, then from
      # `PATH`. `PATH`'s `repro` on a developer machine is whatever the dev
      # shell pins — routinely an older release that does not speak the hook
      # contract — so without this the hook would take the fail-open branch,
      # fire nothing, and every assertion below would pass over a hook that
      # never ran.
      putEnv("REPROBUILD_REPRO", fx.repro)
      defer: delEnv("REPROBUILD_REPRO")

      # ---- (3) a real commit refreshes AND stages. ------------------------
      let newAlpha = moveSibling(fx, "alpha", "revision 2")
      let runsBefore = userHookRuns(fx)
      let commit = tryCommitInApp(fx, "through the managed pre-commit hook")
      if commit.code != 0:
        checkpoint("git commit failed:\n" & commit.output & "\nlog:\n" &
          preCommitLog(fx))
      check commit.code == 0
      check userHookRuns(fx) == runsBefore + 1

      let after = readFile(lockPath(fx))
      if not after.contains(newAlpha):
        checkpoint("the managed pre-commit hook did not refresh the lock.\n" &
          "commit output:\n" & commit.output & "\nlog:\n" & preCommitLog(fx))
      check after.contains(newAlpha)
      check fx.seedSha[0] notin nodeText(after, "alpha-src")
      # THE assertion this whole hook exists for: the commit carries it.
      check lockInCommit(fx) == after
      check gitIn(fx, fx.app, "status --porcelain").strip() == ""
      check lastFlakeLogLine(fx).contains("staged into this commit")

      # ---- (4) the preserved user hook can still refuse. ------------------
      # Coexistence is not "ours wins": a project's own pre-commit checks must
      # still be able to stop a commit, or installing our hook would silently
      # disarm whatever was there.
      writeFile(hooksDir / "pre-commit.repro-local",
        "#!/usr/bin/env sh\n" &
        "echo ran >> " & q(fx.scratch / UserHookMarker) & "\n" &
        "echo 'the project refuses this commit' >&2\n" &
        "exit 7\n")
      var perms = getFilePermissions(hooksDir / "pre-commit.repro-local")
      perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(hooksDir / "pre-commit.repro-local", perms)
      let lockBeforeRefusal = readFile(lockPath(fx))
      let logBeforeRefusal = preCommitLog(fx)
      discard moveSibling(fx, "beta", "revision 2")
      let refused = tryCommitInApp(fx, "a commit the project rejects")
      check refused.code != 0
      check refused.output.contains("the project refuses this commit")
      # The managed body never ran, so it wrote neither the lock nor a log
      # line — the chain stopped where the user's hook stopped it.
      check readFile(lockPath(fx)) == lockBeforeRefusal
      check preCommitLog(fx) == logBeforeRefusal

      # ---- (5) a `repro` that fails the contract does not block a commit. -
      # Put the permissive user hook back so this arm is about the RESOLVED
      # BINARY and nothing else.
      writeFile(hooksDir / "pre-commit.repro-local",
        "#!/usr/bin/env sh\n" &
        "echo ran >> " & q(fx.scratch / UserHookMarker) & "\n" &
        "exit 0\n")
      setFilePermissions(hooksDir / "pre-commit.repro-local", perms)
      let stub = fx.scratch / "stale-repro"
      writeFile(stub,
        "#!/usr/bin/env sh\n" &
        "case \"$1\" in\n" &
        "  --version) echo 'repro 0.0.1-predates-the-handshake'; exit 0 ;;\n" &
        "esac\n" &
        "echo \"error: unknown flag\" >&2\n" &
        "exit 1\n")
      var stubPerms = getFilePermissions(stub)
      stubPerms.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(stub, stubPerms)
      putEnv("REPROBUILD_REPRO", stub)
      let lockBeforeStale = readFile(lockPath(fx))
      let stale = tryCommitInApp(fx, "with a repro that cannot service us")
      if stale.code != 0:
        checkpoint("a stale `repro` BLOCKED a commit, which would make a " &
          "repository uncommittable on any machine whose PATH carries an " &
          "older release:\n" & stale.output)
      check stale.code == 0
      check stale.output.contains("repro hooks")
      # It said so rather than pretending: the mismatch is announced.
      check stale.output.contains("could not be evaluated")
      # …and it changed nothing, which is the honest outcome for a hook that
      # could not run.
      check readFile(lockPath(fx)) == lockBeforeStale
      putEnv("REPROBUILD_REPRO", fx.repro)

      # ---- (6) idempotent. -------------------------------------------------
      let bodyBefore = readFile(hooksDir / "pre-commit.repro-managed")
      let dispatcherBefore = readFile(hooksDir / "pre-commit")
      let localBefore = readFile(hooksDir / "pre-commit.repro-local")
      let again = run(q(fx.repro) & " hooks ensure --vcs " & q(fx.app),
        cwd = fx.app)
      check again.code == 0
      check readFile(hooksDir / "pre-commit.repro-managed") == bodyBefore
      check readFile(hooksDir / "pre-commit") == dispatcherBefore
      # The second run must not re-preserve the dispatcher it just installed
      # as a "user hook" — that is the shadowing loop the RA-4 safeguards
      # exist for, and it would end with our own dispatcher chained to itself.
      check readFile(hooksDir / "pre-commit.repro-local") == localBefore
      check "Reprobuild-managed" notin localBefore

      # ---- (7) uninstall takes it back out. --------------------------------
      let removed = run(q(fx.repro) & " hooks uninstall --vcs " & q(fx.app),
        cwd = fx.app)
      check removed.code == 0
      check not fileExists(hooksDir / "pre-commit.repro-managed")
