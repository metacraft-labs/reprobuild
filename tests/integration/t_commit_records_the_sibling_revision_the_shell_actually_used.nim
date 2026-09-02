## NF-2 (Nix-Flake-Coexistence.md §3.1, §4; Nix-Flake-Coexistence.milestones.org
## §NF-2) — **the headline, and the direct regression test for §3.1**.
##
##   > The common case while developing. `AUTO` builds your local work;
##   > `flake.lock` still names the older revision. **What you built and tested
##   > is not what you published**, and every other consumer — CI, a colleague,
##   > a fresh checkout — gets the pin.
##
## The failure is on the record, twice, in this workspace:
##
##   * `codetracer`'s source called an API that existed only in a newer
##     `nim-agents`; `flake.lock` named the older revision; the developer's
##     shell was green throughout because `AUTO` had been quietly supplying the
##     newer sibling, and CI — which builds the lock — failed with
##     `attempting to call undeclared routine: 'loadSession'`;
##   * Unified-Locking-And-Hooks.md §13.5 records the same failure for
##     `repro.lock`. "The two locks fail identically because they are the same
##     artifact under different names" (§13.6).
##
## ## What is asserted
##
##   0. **the commit CARRIES the refreshed lock.** `git show HEAD:flake.lock`
##      names the sibling's `HEAD`. This is the assertion the whole `pre-commit`
##      placement exists to make available, and it is stated first because it is
##      the one a `post-commit` refresh cannot satisfy: there the lock lands in
##      the working tree AFTER the commit that motivated it, so the revision
##      that shipped still names the old pin and the correction is a second
##      commit somebody has to remember to make (Unified-Locking-And-Hooks.md
##      §13.1 — "the lock then describes the state *before* the commit carrying
##      it");
##   1. after a commit, `flake.lock`'s `alpha-src` node names the SIBLING's
##      `HEAD` — the revision the shell built against — and not the pin it
##      carried before;
##   2. the fields DERIVED from the old revision's content (`narHash`,
##      `lastModified`, `revCount`) are gone from that node. This is not
##      tidiness. Measured on this host with nix 2.32.8: rewriting `rev` and
##      leaving a stale `narHash` behind makes `nix eval` return the OLD
##      revision's content while the lock names the NEW one — no warning, no
##      error. A pin that reads correct and builds something else is §5's
##      inert knob in its purest form, so a refresh that left those fields
##      behind would have REPLACED one silent lie with another;
##   3. the two siblings that did not move keep their nodes BYTE-identical;
##   4. the refresh announces itself in the pre-commit log, naming the input,
##      both revisions, and that it STAGED the result. A refresh nobody can see
##      is indistinguishable from one that did not happen;
##   5. `git commit -a` — which hands the hook a DIFFERENT index file
##      (`.git/index.lock` rather than `.git/index`, measured) — carries the
##      refresh too. Staging into the wrong index is not a near miss there:
##      git holds that lock for the commit in flight, so a `git add` with
##      `GIT_INDEX_FILE` stripped exits 128.
##
## Assertion (5) is made here against the fixture's directly-written hook,
## which does not scrub git's environment. Every commit form through the hook
## `repro hooks ensure --vcs` actually INSTALLS — which does scrub, and which
## therefore has to carry the index across the scrub itself — is asserted by
## `t_every_commit_form_stages_through_the_installed_hook`.
##
## The second case in this suite asks `nix` itself, on a lock `nix flake lock`
## generated, whether the recorded revision is the one an evaluation resolves
## to. That is the only observation here that cannot be satisfied by a refresh
## that wrote plausible bytes, and it is announced LOUDLY when nix is absent.
## The third asks nix the follow-up question the `narHash` decision rests on:
## does a refreshed lock stay put under a lock-WRITING evaluation?
##
## ## Mutation (from the milestone): skip the refresh ⇒ RED
##
## The pre-commit hook no longer refreshes `flake.lock`. Asserts (0) and (1)
## then read the seed revision where the sibling's second commit was expected —
## reproducing the published-what-you-never-built failure exactly.
##
## Test-double policy: NO mocks, doubles or fakes. See the header of
## `nf2_flake_lock_fixture.nim` for the full inventory of real components.

import std/[json, os, strutils, times, unittest]

import nf2_flake_lock_fixture

suite "NF-2: the commit records the sibling revision the shell used":

  test "t_commit_records_the_sibling_revision_the_shell_actually_used":
    if not nf2Prerequisites(
        "t_commit_records_the_sibling_revision_the_shell_actually_used"):
      skip()
    else:
      let fx = setupNf2Fixture("headline")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      let before = readFile(lockPath(fx))
      let seedAlpha = fx.seedSha[0]
      check nodeText(before, "alpha-src").contains(seedAlpha)

      # The sibling moves ahead of its pin: this is `AUTO` building local work.
      let newAlpha = moveSibling(fx, "alpha", "revision 2")
      check newAlpha != seedAlpha

      # A REAL `git commit`. The installed `pre-commit` hook fires inside it.
      let commit = tryCommitInApp(fx, "call the newer alpha API")
      # The hook must never fail a commit — a non-zero pre-commit status
      # ABORTS it, and nothing this refresh does is a reason to reject work.
      if commit.code != 0:
        checkpoint("git commit failed:\n" & commit.output & "\nlog:\n" &
          preCommitLog(fx))
      check commit.code == 0

      let after = readFile(lockPath(fx))
      let doc = parseJson(after)
      let alphaLocked = doc["nodes"]["alpha-src"]["locked"]

      # ---- (0) the COMMIT carries it. -------------------------------------
      # Read out of git's object store, not off disk. A post-commit refresh
      # passes every other assertion in this case and fails this one.
      let committed = lockInCommit(fx)
      if committed != after:
        checkpoint("the commit does not carry the refreshed lock.\n" &
          "worktree:\n" & after & "\nHEAD:\n" & committed & "\nlog:\n" &
          preCommitLog(fx))
      check committed == after
      check parseJson(committed)["nodes"]["alpha-src"]["locked"][
        "rev"].getStr() == newAlpha
      # …and nothing is left over for a follow-up commit to sweep up: the
      # working tree is clean, so there is no "modification the developer did
      # not make" for them to notice, explain or forget.
      check gitIn(fx, fx.app, "status --porcelain").strip() == ""

      # ---- (1) the pin names what the shell built. ------------------------
      if alphaLocked["rev"].getStr() != newAlpha:
        checkpoint("log:\n" & preCommitLog(fx) & "\nlock:\n" & after)
      check alphaLocked["rev"].getStr() == newAlpha
      check seedAlpha notin nodeText(after, "alpha-src")

      # ---- (2) the derived fields are gone, not stale. ---------------------
      check not alphaLocked.hasKey("narHash")
      check not alphaLocked.hasKey("lastModified")
      check not alphaLocked.hasKey("revCount")
      # …and the fields that describe the input rather than the revision are
      # untouched, so the node is still a usable git input.
      check alphaLocked["type"].getStr() == "git"
      check alphaLocked["ref"].getStr() == "main"
      check alphaLocked["url"].getStr() == originUrl(fx, "alpha")

      # ---- (3) the siblings that did not move are byte-identical. ---------
      check nodeText(after, "beta-src") == nodeText(before, "beta-src")
      check nodeText(after, "gamma-src") == nodeText(before, "gamma-src")

      # ---- (4) the refresh said so. ---------------------------------------
      let log = lastFlakeLogLine(fx)
      check log.contains("flake-lock refreshed")
      check log.contains("alpha-src")
      check log.contains(newAlpha)
      # …including that it STAGED what it wrote. A refresh that rewrote the
      # file but did not stage it produces a commit naming the old revision
      # with the new one sitting unstaged beside it — the §3.1 failure with an
      # extra step, and indistinguishable from success in a log that only said
      # "refreshed".
      check log.contains("staged into this commit")

      # ---- (5) `git commit -a`, which hands the hook a DIFFERENT index. ---
      # Measured on this host with git 2.50, printing `GIT_INDEX_FILE` from a
      # real pre-commit hook: `git commit` and `git commit --amend` pass
      # `.git/index`, but `git commit -a` passes `.git/index.lock` and
      # `git commit -- <paths>` passes `.git/next-index-<pid>.lock`. Staging
      # into the wrong one is not a near miss — git holds the lock for the
      # commit in flight, so a `git add` that ignores the variable exits 128.
      # Every arm above uses the plain form, where the variable happens to name
      # the ordinary index and a stripped environment works by luck; this arm
      # is the one that does not.
      # The tracked file is seeded and committed FIRST, while nothing has
      # moved, so the `-a` commit below is the only one with a refresh to do.
      # (Seeding after a sibling move would have let the seed commit perform
      # the refresh and left `-a` with nothing to prove.)
      writeFile(fx.app / "tracked.txt", "seed\n")
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q -m " & q("seed a tracked file"))
      let newBeta = moveSibling(fx, "beta", "revision 2")
      writeFile(fx.app / "tracked.txt", "modified, committed with -a\n")
      let dashA = run(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q -a -m " & q("commit -a against a moved beta"))
      if dashA.code != 0:
        checkpoint("`git commit -a` failed:\n" & dashA.output & "\nlog:\n" &
          preCommitLog(fx))
      check dashA.code == 0
      let dashALock = readFile(lockPath(fx))
      if not dashALock.contains(newBeta):
        checkpoint("`git commit -a` did not carry the refresh; log:\n" &
          preCommitLog(fx))
      check dashALock.contains(newBeta)
      check lockInCommit(fx) == dashALock
      check gitIn(fx, fx.app, "status --porcelain").strip() == ""
      check lastFlakeLogLine(fx).contains("staged into this commit")

  test "t_commit_records_the_sibling_revision_nix_resolves_to_it":
    ## The observation that a plausible-looking write cannot satisfy: ask NIX,
    ## on a lock `nix flake lock` itself generated, what the refreshed lock
    ## resolves to. §5's motivating failure was a mechanism that "looked like
    ## it was working while doing nothing", so a case that only compares bytes
    ## it wrote against bytes it expected is not enough on its own.
    if not nf2Prerequisites(
        "t_commit_records_the_sibling_revision_nix_resolves_to_it"):
      skip()
    else:
      let nixBin = findExe("nix")
      if nixBin.len == 0:
        echo "SKIPPED (loudly): " &
          "t_commit_records_the_sibling_revision_nix_resolves_to_it needs " &
          "`nix` on PATH to ask what the refreshed lock RESOLVES to; " &
          "nix=MISSING. The content assertions in the case above still ran, " &
          "but 'the recorded revision is the one nix evaluates' was NOT " &
          "checked by this run — and that is exactly the distinction a stale " &
          "`narHash` erases."
        skip()
      else:
        let fx = setupNf2Fixture("headline-nix")
        defer: removeDir(fx.scratch)
        isolateNf2Config(fx)
        defer: releaseNf2Config()

        # A flake that READS from the sibling, so an evaluation has to resolve
        # the input rather than merely parse the lock.
        writeFile(fx.app / "flake.nix",
          "{\n" &
          "  inputs.alpha-src.url = \"git+" & originUrl(fx, "alpha") &
            "?ref=main\";\n" &
          "  outputs = { self, alpha-src }: {\n" &
          "    marker = builtins.readFile (alpha-src + \"/marker.txt\");\n" &
          "  };\n" &
          "}\n")
        removeFile(lockPath(fx))
        let nixPrefix = q(nixBin) &
          " --extra-experimental-features 'nix-command flakes' "
        let locked = run(nixPrefix & "flake lock --offline", cwd = fx.app)
        if locked.code != 0 or not fileExists(lockPath(fx)):
          echo "SKIPPED (loudly): `nix flake lock` could not produce a " &
            "flake.lock for this fixture, so the nix-resolved assertions " &
            "cannot run. Output:\n" & locked.output
          skip()
        else:
          discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
          discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) &
            " commit -q -m " & q("lock the flake"))

          # The sibling moves, and its new revision is PUBLISHED so nix can
          # fetch it — a pin nobody else can obtain is a different defect,
          # and it is NF-3's.
          let newAlpha = moveSibling(fx, "alpha", "revision 2")
          discard requireCmd(q(fx.gitBin) & " -C " &
            q(siblingDir(fx, "alpha")) & " push -q origin main")

          # Before the refresh, the lock still resolves to the OLD content.
          # This is §3.1 stated as an evaluation rather than as a diff.
          # stdout and stderr are captured SEPARATELY: `nix eval` writes a
          # "Git tree … is dirty" warning to stderr on every run against a
          # working tree, and `execCmdEx` merges the two by default — which
          # would put a diagnostic inside the value under test.
          #
          # `--no-write-lock-file` is deliberate HERE and only here: this case
          # is about which CONTENT the lock resolves to, and it evaluates a
          # deliberately stale lock, which nix would be entitled to update.
          # Whether a REFRESHED lock churns under a lock-writing evaluation is
          # a different question, and it is asked — without this flag — by
          # `t_a_refreshed_lock_does_not_churn_under_nix` below. Answering it
          # here would be answering it with the flag that makes it unanswerable.
          proc evalMarker(): tuple[code: int; value: string] =
            let outFile = fx.scratch / "nix-eval.out"
            let errFile = fx.scratch / "nix-eval.err"
            let res = run(nixPrefix &
              "eval --offline --no-write-lock-file --raw .#marker >" &
              q(outFile) & " 2>" & q(errFile), cwd = fx.app)
            (code: res.code, value: readFile(outFile).strip())

          let stale = evalMarker()
          check stale.code == 0
          check stale.value == "alpha revision 1"

          let commit = tryCommitInApp(fx, "use the newer alpha")
          if commit.code != 0:
            checkpoint("git commit failed:\n" & commit.output)
          check commit.code == 0
          check parseJson(readFile(lockPath(fx)))["nodes"]["alpha-src"][
            "locked"]["rev"].getStr() == newAlpha

          # THE assertion: what nix resolves the refreshed lock to is the new
          # revision's CONTENT. A refresh that rewrote `rev` and left the
          # previous revision's `narHash` in place passes every byte-level
          # check above and fails this one, returning "alpha revision 1".
          let fresh = evalMarker()
          if fresh.code != 0:
            checkpoint("nix eval failed; lock:\n" & readFile(lockPath(fx)))
          check fresh.code == 0
          check fresh.value == "alpha revision 2"

  test "t_a_refreshed_lock_does_not_churn_under_nix":
    ## The consequence of the `narHash` decision, asked of nix rather than
    ## argued about.
    ##
    ## ## The decision, and the three options it was chosen from
    ##
    ## A `locked` node for a git input carries `rev` plus three fields derived
    ## from that revision's CONTENT — `narHash`, `lastModified`, `revCount`.
    ## Moving `rev` invalidates all three, and there are only three things a
    ## refresh can do about them:
    ##
    ##   (i)   **leave them.** Measured on this host with nix 2.32.8: nix then
    ##         resolves the OLD tree while the lock names the NEW revision, with
    ##         no warning and no error. That is the case immediately above, and
    ##         it is §5's inert knob — a pin that reads correct and builds
    ##         something else. Rejected outright.
    ##   (ii)  **recompute them.** Not rejected on the "never run the solver on
    ##         the commit path" rule — re-pinning one input to a known revision
    ##         is not a solve — but on what the computation needs. A correct
    ##         `narHash` requires nix to FETCH that revision from the input's
    ##         declared URL. Measured: ~120 ms per input when nix already has
    ##         the revision (against a ~65 ms floor for starting nix at all),
    ##         ~135–180 ms cold, and an outright FAILURE (`Failed to fetch git
    ##         repository … fatal: git upload-pack`) when the revision exists
    ##         only in the sibling's local checkout while the input's URL is
    ##         that sibling's origin. That last case is the normal state on a
    ##         commit hook: a developer commits in a sibling, then commits here,
    ##         before either is pushed. So (ii) would cost per-commit latency
    ##         and still produce no hash exactly when the refresh matters most.
    ##   (iii) **delete them.** Chosen.
    ##
    ## ## Why (iii) needs a test of its own
    ##
    ## (iii) has one plausible objection, and it is not about correctness: if
    ## nix RE-ADDS the fields on the next evaluation, then `flake.lock` changes
    ## underfoot after every refresh. That is lock churn — `direnv`'s
    ## `watch_file` on `flake.lock` re-fires, every tree watcher sees a modified
    ## input, and "most commits do not touch the lock" (§13.3) is defeated one
    ## evaluation later rather than at the commit.
    ##
    ## Measured, and pinned here: it does not happen. With lock writing ALLOWED
    ## — no `--no-write-lock-file`, which is the flag that would make this
    ## question unanswerable — repeated evaluations against a clean tree leave
    ## the refreshed lock BYTE- and MTIME-identical, `git status` empty, and
    ## still resolving to the new revision's content.
    ##
    ## Test-double policy: NO mocks. Real nix, real git, real evaluations.
    if not nf2Prerequisites("t_a_refreshed_lock_does_not_churn_under_nix"):
      skip()
    else:
      let nixBin = findExe("nix")
      if nixBin.len == 0:
        echo "SKIPPED (loudly): t_a_refreshed_lock_does_not_churn_under_nix " &
          "needs `nix` on PATH — the whole case is 'what does nix do to a " &
          "refreshed lock', and nothing about it can be answered without " &
          "nix. nix=MISSING. NOT CHECKED by this run: that a refresh does " &
          "not make the next evaluation rewrite flake.lock, which is the " &
          "objection the delete-the-derived-fields decision rests on."
        skip()
      else:
        let fx = setupNf2Fixture("nix-churn")
        defer: removeDir(fx.scratch)
        isolateNf2Config(fx)
        defer: releaseNf2Config()

        writeFile(fx.app / "flake.nix",
          "{\n" &
          "  inputs.alpha-src.url = \"git+" & originUrl(fx, "alpha") &
            "?ref=main\";\n" &
          "  outputs = { self, alpha-src }: {\n" &
          "    marker = builtins.readFile (alpha-src + \"/marker.txt\");\n" &
          "  };\n" &
          "}\n")
        removeFile(lockPath(fx))
        let nixPrefix = q(nixBin) &
          " --extra-experimental-features 'nix-command flakes' "
        # The lock nix itself generates, so the fields under discussion are
        # present with the values nix chose rather than ones this test wrote.
        discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
        let locked = run(nixPrefix & "flake lock --offline", cwd = fx.app)
        if locked.code != 0 or not fileExists(lockPath(fx)):
          echo "SKIPPED (loudly): `nix flake lock` could not produce a " &
            "flake.lock for this fixture, so there is no nix-authored lock " &
            "to refresh and the churn question cannot be asked. NOT CHECKED " &
            "by this run: that a refreshed lock survives a lock-writing " &
            "evaluation unchanged. Output:\n" & locked.output
          skip()
        else:
          check readFile(lockPath(fx)).contains("narHash")
          discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
          discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) &
            " commit -q -m " & q("lock the flake"))

          # The sibling moves, and is published so nix can resolve the new
          # revision offline through the input's declared URL.
          let newAlpha = moveSibling(fx, "alpha", "revision 2")
          discard requireCmd(q(fx.gitBin) & " -C " &
            q(siblingDir(fx, "alpha")) & " push -q origin main")

          let commit = tryCommitInApp(fx, "use the newer alpha")
          if commit.code != 0:
            checkpoint("git commit failed:\n" & commit.output)
          check commit.code == 0

          let refreshed = readFile(lockPath(fx))
          let alphaLocked = parseJson(refreshed)["nodes"]["alpha-src"]["locked"]
          check alphaLocked["rev"].getStr() == newAlpha
          check not alphaLocked.hasKey("narHash")
          # The tree must be CLEAN for this question to be the right one: a
          # dirty tree makes nix print "Git tree … is dirty" and changes what
          # it is entitled to do, and the state after a pre-commit refresh is
          # precisely a clean tree whose HEAD carries the refreshed lock.
          check gitIn(fx, fx.app, "status --porcelain").strip() == ""
          # One second of separation so a rewrite-to-identical-content is
          # visible as a touch even at one-second timestamp resolution.
          sleep(1100)
          let mtimeAfterRefresh = getLastModificationTime(lockPath(fx))

          # ---- lock writing ALLOWED, four times over. ---------------------
          var evaluations = 0
          for i in 1 .. 2:
            for verb in ["eval --offline --raw .#marker",
                         "flake metadata --offline --json"]:
              let res = run(nixPrefix & verb & " >/dev/null 2>&1", cwd = fx.app)
              if res.code != 0:
                checkpoint("`nix " & verb & "` exited " & $res.code &
                  "; lock:\n" & readFile(lockPath(fx)))
              check res.code == 0
              inc evaluations
          # Positively stated: a case where nothing ran would satisfy every
          # "unchanged" assertion below for the wrong reason.
          check evaluations == 4

          if readFile(lockPath(fx)) != refreshed:
            checkpoint("nix REWROTE the refreshed lock:\n--- before ---\n" &
              refreshed & "\n--- after ---\n" & readFile(lockPath(fx)))
          check readFile(lockPath(fx)) == refreshed
          check getLastModificationTime(lockPath(fx)) == mtimeAfterRefresh
          check gitIn(fx, fx.app, "status --porcelain").strip() == ""

          # …and it is still resolving the NEW revision, so "unchanged" is not
          # "nix ignored the lock".
          let outFile = fx.scratch / "churn-eval.out"
          let ev = run(nixPrefix & "eval --offline --raw .#marker >" &
            q(outFile) & " 2>/dev/null", cwd = fx.app)
          check ev.code == 0
          check readFile(outFile).strip() == "alpha revision 2"
