## NF-2 — **a sibling revision that has never been pushed must not be recorded
## as a `flake.lock` pin.**
##
## Spec: Workspace-And-Develop-Mode.md §"Reproducibility And `repro check`" —
## a develop-mode dependency that is
##
##   > dirty **or only locally committed**
##
## means "the effective build state is not properly lockable for other people
## yet". NF-2 already honoured three members of that family: a DIRTY sibling
## (skip, leave the pin, do not refuse the commit), a BEHIND-pin sibling, and a
## sibling whose pin is not fetched locally. **Only locally committed** is the
## fourth, and it was unhandled.
##
## ## The defect this is the regression test for — observed live 2026-09-13
##
## `repro flake refresh-lock` recorded `runquota-src` at
## `18f64e103c19453b939882c9190c7c180934bb3d`, a commit that existed only in the
## local checkout and had never been pushed. The resulting `flake.lock` named
## content nobody else can obtain, and nix answered
##
##     error: unable to download
##     'https://api.github.com/repos/metacraft-labs/runquota/tarball/18f64e10…':
##     HTTP error 404
##     direnv: nix-direnv: Evaluating current devShell failed.
##             Falling back to previous environment!
##
## The failure is silent in the worst way: nix-direnv falls back to the
## PREVIOUS environment instead of failing, so the developer keeps working in a
## stale shell while the lock claims something else. `codetracer` and
## `codetracer-native-recorder` were in the same state at the same moment, so
## it is systemic rather than a one-off.
##
## ## The policy asserted here
##
## The same shape as the other three: **skip that input's refresh, leave the
## lock, and let the commit proceed**. Refusing the commit would be new
## behaviour the policy does not ask for, and it would reject work that is
## already correct. NF-3's pre-push gate is where an unpublished sibling is
## refused — it already verifies that every develop-set HEAD is published — so
## declining to record here is what stops one half of the campaign writing what
## the other half rejects.
##
## ## What is asserted
##
##   1. the arrangement really is one — `gamma`'s HEAD is reachable from no
##      remote-tracking ref, asked with git's own predicate. Without this the
##      case could pass over a sibling that was quietly published;
##   2. the commit SUCCEEDS. A pre-commit hook that rejected the developer's
##      work here would be the wrong remedy for the wrong problem;
##   3. `flake.lock` in the working tree is **byte-identical** afterwards — the
##      whole file, not just the `gamma-src` node, because a refresh that moved
##      the pin and moved it back, or that reserialised the document, is not the
##      same thing as one that never touched it;
##   4. `flake.lock` **as the commit carries it** is byte-identical too. The
##      working-tree file answers "was anything written"; only the committed
##      blob answers "did this revision file an unobtainable pin";
##   5. the skip is SAID, naming the sibling and the revision. A skip nobody can
##      see is indistinguishable from a refresh that silently did nothing, which
##      is this campaign's own motivating bug reproduced one level up.
##
## ## Mutation
##
## Record it anyway — drop `and not row.unpublished` from
## `flakeRowIsRecordable` ⇒ RED on (3), (4) and (5): the `gamma-src` node names
## the local-only revision, the file is no longer byte-identical, and nothing is
## withheld.
##
## ## The second case in this file
##
## `t_an_unprovable_publication_is_not_read_as_published` covers the other way
## the verdict can come out negative: the probe FAILS instead of answering. It
## is here rather than in a file of its own because it is the same predicate
## with the same rule applied to it — unproven is not "published" — and reading
## the two arrangements side by side is the point.
##
## Test-double policy: NO mocks, doubles or fakes — real bare git origins, real
## clones, a real `git push` (and, here, its deliberate ABSENCE), a real
## `flake.lock` in nix's on-disk shape, the real `./build/bin/repro`, and a REAL
## `.git/hooks/pre-commit` fired by a real `git commit`. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-2: an unpushed sibling revision is not recorded":

  test "t_an_unpushed_sibling_revision_is_not_recorded":
    const caseName = "t_an_unpushed_sibling_revision_is_not_recorded"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("unpushed-not-recorded")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # The starting lock names every sibling's seed revision, and every seed
      # revision was pushed by `seedOrigin`. Publishing `app` itself keeps the
      # rest of the workspace in the state the other cases start from.
      commitLockAndPublish(fx, "a lock that names every sibling's seed")
      let before = readFile(lockPath(fx))
      check nodeText(before, "gamma-src").contains(fx.seedSha[2])

      # gamma gains a commit and it is NOT pushed. This is the field shape
      # exactly: you commit a sibling, then commit the consumer.
      let localOnly = moveSibling(fx, "gamma",
        "a revision that never left this machine")
      check localOnly != fx.seedSha[2]

      # ---- (1) the arrangement is what the case claims ------------------
      check not siblingRevIsPublished(fx, "gamma", localOnly)
      check siblingRevIsPublished(fx, "gamma", fx.seedSha[2])

      # ---- (2) the commit SUCCEEDS --------------------------------------
      let committed = tryCommitInApp(fx, "work built against a local gamma")
      checkpoint("commit output:\n" & committed.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check committed.code == 0

      # ---- (3) the working-tree lock is BYTE-identical ------------------
      let after = readFile(lockPath(fx))
      if after != before:
        checkpoint("gamma-src BEFORE:\n" & nodeText(before, "gamma-src"))
        checkpoint("gamma-src AFTER:\n" & nodeText(after, "gamma-src"))
      check after == before
      check nodeText(after, "gamma-src").contains(fx.seedSha[2])
      check not after.contains(localOnly)

      # ---- (4) the COMMIT carries the unchanged lock --------------------
      let carried = lockInCommit(fx)
      check carried.len > 0
      if carried != before:
        checkpoint("gamma-src AS COMMITTED:\n" & nodeText(carried, "gamma-src"))
      check carried == before
      check not carried.contains(localOnly)

      # ---- (5) …and the skip was SAID -----------------------------------
      var notice: string
      for line in committed.output.splitLines():
        if line.contains("NOT refreshed") and line.contains("gamma-src"):
          notice = line
      checkpoint("notice: " & notice)
      check notice.len > 0
      check notice.contains("gamma")
      check notice.contains(localOnly)
      check notice.contains("ONLY in this local checkout")

      let logLine = lastFlakeLogLine(fx)
      checkpoint("last flake-lock log line: " & logLine)
      check logLine.contains("skipped-unrecordable-sibling")

  test "t_an_unprovable_publication_is_not_read_as_published":
    ## The other half of the publication verdict: what happens when the probe
    ## itself cannot answer.
    ##
    ## `flakeClassifyPublication` asks one question — `git rev-list
    ## --max-count=1 <rev> --not --remotes` — and that command can fail rather
    ## than answer. A broken ref under `refs/remotes/` is enough: git exits 128
    ## with `fatal: bad object`, having said nothing about reachability.
    ##
    ## UNPROVEN IS NOT "PUBLISHED". This is the rule `fprUnfetched` already
    ## follows one axis over — a pin that cannot be established must not be
    ## filed — and it is the direction that keeps every uncertainty in this
    ## mechanism fail-safe: the lock keeps a pin that IS obtainable, nothing is
    ## written, and nothing is refused.
    ##
    ## The arrangement is the exact opposite of the case above: gamma's HEAD is
    ## genuinely PUBLISHED, so recording it is correct and would happen — and
    ## the only thing standing in the way is that the probe cannot say so.
    ##
    ## Mutation: treat a failed probe as published (drop the
    ## `result.unpublished = true` from the `unreachable.code != 0` arm) ⇒ RED:
    ## the pin moves to a revision this run never established as obtainable.
    const caseName = "t_an_unprovable_publication_is_not_read_as_published"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("unprovable-publication")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      commitLockAndPublish(fx, "a lock that names every sibling's seed")
      let before = readFile(lockPath(fx))

      let published = moveAndPublishSibling(fx, "gamma", "a pushed revision")
      check siblingRevIsPublished(fx, "gamma", published)

      # A real broken remote-tracking ref, written the way a truncated fetch or
      # a damaged object store leaves one. Asserted to really break the probe
      # rather than assumed: if a future git starts tolerating it, this case
      # must say so instead of passing over an arrangement it never reached.
      createDir(siblingDir(fx, "gamma") / ".git" / "refs" / "remotes" / "origin")
      writeFile(siblingDir(fx, "gamma") / ".git" / "refs" / "remotes" /
        "origin" / "broken", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n")
      let probe = run(q(fx.gitBin) & " -C " & q(siblingDir(fx, "gamma")) &
        " rev-list --max-count=1 " & published & " --not --remotes")
      checkpoint("probe -> " & $probe.code & " " & probe.output)
      check probe.code != 0

      let committed = tryCommitInApp(fx, "work built against a pushed gamma")
      checkpoint("commit output:\n" & committed.output)
      check committed.code == 0

      let after = readFile(lockPath(fx))
      if after != before:
        checkpoint("gamma-src AFTER:\n" & nodeText(after, "gamma-src"))
      check after == before
      check not after.contains(published)
      check lockInCommit(fx) == before

      var notice: string
      for line in committed.output.splitLines():
        if line.contains("NOT refreshed") and line.contains("gamma-src"):
          notice = line
      checkpoint("notice: " & notice)
      check notice.len > 0
      check notice.contains("could not be shown to exist anywhere but this")
      # …and it does NOT make the stronger claim the probe never established.
      check not notice.contains("ONLY in this local checkout")
