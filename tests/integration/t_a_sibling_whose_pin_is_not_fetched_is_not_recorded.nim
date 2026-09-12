## NF-2/NF-3 — **a sibling whose pinned revision has not been fetched is
## classified as such, and is never recorded.**
##
## Spec: Nix-Flake-Coexistence.md §3.2 (the behind/ahead asymmetry) and NF-1's
## standing rule that **an empty result and a failure must not look alike** —
## applied here to a third thing that used to look like both.
##
## ## The case, and how it nearly landed the downgrade twice
##
## Classification needs the pinned commit in the sibling's object store: the
## AT/not-at half is a string comparison, but the DIRECTION is `git rev-list
## --left-right`. When the pin has never been fetched — a colleague pushed, the
## lock was refreshed elsewhere, this checkout has not fetched since — there is
## no direction to compute, and every such sibling was reported as `unknown`:
## indistinguishable from a broken `git`, an unreadable `HEAD`, or a
## `rev-list` that answered something unparseable.
##
## Measured in this workspace during the landing that motivated this change:
## `io-mon` was **5 commits behind** its pin and was reported `unknown` purely
## because the pin had not been fetched. A refresh that recorded `HEAD` in that
## state would have filed a 5-commit downgrade — the very defect the behind-pin
## rule exists to prevent, reached through the one classification that did not
## know it was looking at it.
##
## So an unfetched pin is neither "unknown" nor "at": it is **cannot be
## classified until fetched**, it names the fetch, and — the load-bearing half —
## it is **not recordable**. An unclassifiable sibling must never be filed as a
## pin, because "we could not tell" is not a revision.
##
## ## What is asserted
##
##   1. the arrangement is real: the pinned revision genuinely is NOT in the
##      sibling's object store (asked with git's own `cat-file -e`, the same
##      predicate the classifier uses);
##   2. the commit SUCCEEDS and `flake.lock` is byte-identical — nothing was
##      recorded;
##   3. the diagnostic DISTINGUISHES this from every other cause: it says the
##      sibling cannot be classified until it is fetched, it does not claim a
##      direction, and `repro flake override-status --json` reports the row's
##      relation as `unfetched` rather than `unknown`, `at` or `behind`;
##   4. it names the FETCH, as a pasteable command — and that command, run from
##      the directory the message names, really does make the sibling
##      classifiable;
##   5. once fetched, the sibling turns out to be **5 commits behind**, and is
##      STILL not recorded. That is the whole story in one assertion: the
##      classification changed, the refusal to file a downgrade did not.
##
## ## Mutations
##
##   * treat an unfetched pin as AT the pin (return `fprAt`) ⇒ RED on (3): the
##     row reports `at`, the diagnostic names no fetch, and (5)'s re-check finds
##     no notice at all;
##   * treat it as BEHIND with distance 0 ⇒ RED on (3): the relation is `behind`
##     and the "cannot be classified until fetched" wording is gone;
##   * make it recordable ⇒ RED on (2).
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, osproc, strutils, unittest]

import nf3_override_state_fixture

proc withheldNotice(text: string): string =
  for line in text.splitLines():
    if line.contains("NOT refreshed") and line.contains("gamma-src"):
      return line
  ""

suite "NF-2: a sibling whose pin is not fetched is not recorded":

  test "t_a_sibling_whose_pin_is_not_fetched_is_not_recorded":
    const caseName = "t_a_sibling_whose_pin_is_not_fetched_is_not_recorded"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let shell = findExe("bash")
      if shell.len == 0:
        echo "SKIPPED (loudly): " & caseName & " needs `bash` on PATH to " &
          "check that the printed fetch command parses as a shell command; " &
          "bash=MISSING"
        skip()
      else:
        let fx = setupNf2Fixture("unfetched-pin")
        defer: removeDir(fx.scratch)
        isolateNf2Config(fx)
        defer: releaseNf2Config()

        # gamma's ORIGIN gains five revisions from a side clone; `ws/gamma` is
        # never fetched, so the tip the lock is about to pin is not in its
        # object store.
        let gammaPinned = advanceOriginWithoutFetching(fx, "gamma", 5)
        check gammaPinned != fx.seedSha[2]
        check headOf(fx, siblingDir(fx, "gamma")) == fx.seedSha[2]

        # ---- (1) the arrangement is real ---------------------------------
        check not pinIsFetched(fx, "gamma", gammaPinned)

        setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned)
        commitLockAndPublish(fx, "a lock pinned at an unfetched gamma")
        let before = readFile(lockPath(fx))

        # ---- (2) the commit stands and nothing is recorded ---------------
        let committed = tryCommitInApp(fx, "work made without fetching gamma")
        checkpoint("commit output:\n" & committed.output)
        checkpoint("pre-commit log:\n" & preCommitLog(fx))
        check committed.code == 0
        let after = readFile(lockPath(fx))
        if after != before:
          checkpoint("gamma-src BEFORE:\n" & nodeText(before, "gamma-src"))
          checkpoint("gamma-src AFTER:\n" & nodeText(after, "gamma-src"))
        check after == before
        check not nodeText(after, "gamma-src").contains(fx.seedSha[2])
        check lockInCommit(fx) == before

        # ---- (3) it is DISTINGUISHED from every other cause --------------
        let notice = withheldNotice(committed.output)
        checkpoint("notice: " & notice)
        check notice.len > 0
        check notice.contains("CANNOT BE CLASSIFIED")
        check notice.contains("until it is fetched")
        check not notice.contains("BEHIND")
        check not notice.contains("AHEAD")

        let js = flakeStatus(fx, "--json")
        checkpoint("override-status stderr:\n" & js.stderr)
        check js.code == 0
        let doc = parseJson(js.stdout)
        let row = statusRow(doc, "gamma-src")
        # `check` over a BOOL rather than over the node: `unittest` stringifies
        # both operands of a failing `check`, and `$` on a nil `JsonNode` takes
        # the process down at the moment it was supposed to print why.
        let haveRow = row != nil
        check haveRow
        if haveRow:
          checkpoint("gamma-src row: " & $row)
          check row["relation"].getStr() == "unfetched"
        let counts = doc["counts"]
        checkpoint("counts: " & $counts)
        let hasUnfetchedCount = counts.hasKey("unfetched")
        check hasUnfetchedCount
        if hasUnfetchedCount:
          check counts["unfetched"].getInt() == 1
        check counts["unknown"].getInt() == 0
        check counts["behind"].getInt() == 0
        check counts["at"].getInt() == 2

        # ---- (4) the named FETCH is pasteable, and works -----------------
        let namedDir = directoryNamedForRunning(notice)
        checkpoint("named directory: " & namedDir)
        check namedDir.len > 0
        check dirExists(namedDir)
        let commands = backtickedCommands(notice)
        checkpoint("commands: " & $commands)
        check commands.len >= 1
        if commands.len >= 1:
          check commands[0].contains("fetch")
          for cmd in commands:
            check cmd.splitLines().len == 1
            let parsed = execCmdEx(q(shell) & " -n -c " & q(cmd))
            checkpoint("bash -n `" & cmd & "` -> " & $parsed.exitCode & " " &
              parsed.output)
            check parsed.exitCode == 0
          let fetched = runNamedCommand(fx, commands[0], namedDir)
          checkpoint("ran `" & commands[0] & "` in " & namedDir & " -> " &
            $fetched.code & "\n" & fetched.output)
          check fetched.code == 0
          check pinIsFetched(fx, "gamma", gammaPinned)

          # ---- (5) …and it was 5 behind all along, still not recorded ----
          let again = firePreCommitHook(fx)
          checkpoint("re-fired hook -> " & $again.code & "\n" & again.output)
          check again.code == 0
          let second = withheldNotice(again.output)
          checkpoint("second notice: " & second)
          check second.contains("5 commit(s) BEHIND")
          check not second.contains("CANNOT BE CLASSIFIED")
          check readFile(lockPath(fx)) == before

          let js2 = flakeStatus(fx, "--json")
          let doc2 = parseJson(js2.stdout)
          let row2 = statusRow(doc2, "gamma-src")
          let haveRow2 = row2 != nil
          check haveRow2
          if haveRow2:
            check row2["relation"].getStr() == "behind"
            check row2["behindBy"].getInt() == 5
