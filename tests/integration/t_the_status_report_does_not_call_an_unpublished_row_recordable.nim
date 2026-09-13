## NF-2 — **`repro flake override-status --json` must not call a row
## `recordable` that the refresh will withhold.**
##
## Spec: Nix-Flake-Coexistence.md §3.2 (the report), §5 (the machine-readable
## surface), and Workspace-And-Develop-Mode.md §"Reproducibility And
## `repro check`" ("dirty **or only locally committed**").
##
## ## The failure mode this exists to prevent
##
## `recordable` is the ONE field in the §5 document that answers "will the
## refresh file this row's revision into `flake.lock`?". It is computed by
## `flakeRowIsRecordable`, which is deliberately the single predicate every
## consumer answers through — the refresh, the gate and this report — so that
## no two of them can grow different opinions.
##
## The publication axis broke that. `flakeRowIsRecordable` gained `and not
## row.unpublished`, but `row.unpublished` is only ever set by
## `flakeAnnotatePublication`, and the report did not call it. So for a sibling
## that is AHEAD of its pin at a revision which exists only in the local
## checkout, the report answered `"recordable": true` while the refresh
## withheld the write — the two halves disagreeing about the same row, in the
## same workspace, in the same second.
##
## That is the quiet kind of wrong this campaign exists to remove. The field is
## the machine-readable surface: a script that gates on it is told the pin will
## move, and the pin does not move, and nothing in either output says why.
##
## ## Why annotating here costs nothing
##
## `flakeAnnotatePublication` is deliberately NOT asked by
## `flakeOverrideStateReport`, because that derivation also backs
## `repro flake override-args`, which `.envrc` runs on every directory entry.
## `override-status` is not that path — §"the cheap, wrong report" line was
## deleted from `.envrc`, and this verb now exists for CI, scripts and `--json`.
## It already resolves the develop set, so one `git rev-list` per substituted
## input is not a cost worth being wrong for.
##
## ## What is asserted
##
##   1. the arrangement is real, asked with git's own predicate: `gamma` is
##      ahead of its pin at a revision reachable from no remote-tracking ref,
##      and `alpha` is ahead at one that IS;
##   2. the report classifies BOTH as `ahead` — the direction axis is untouched,
##      so a fix that reclassified the row instead of annotating it fails here;
##   3. `gamma-src` is `"recordable": false` and `alpha-src` is
##      `"recordable": true` — the asymmetry, on the one field that predicts the
##      refresh;
##   4. and the prediction is CHECKED against the refresh rather than trusted:
##      the same workspace is then committed, and exactly the row the report
##      called recordable is the row whose pin moved.
##
## Assertion (4) is what makes this a consistency case rather than a
## restatement of the implementation. Without it, a report and a refresh that
## were wrong in the same way would both pass.
##
## ## Mutation
##
## Drop the `flakeAnnotatePublication` call from
## `runFlakeOverrideStatusCommand` ⇒ RED on (3): `gamma-src` is reported
## recordable and the commit then declines to record it, which is (4).
##
## Test-double policy: NO mocks, doubles or fakes — real bare git origins, real
## clones, a real `git push` and its deliberate absence, a real `flake.lock` in
## nix's on-disk shape, the real `./build/bin/repro`, and a REAL
## `.git/hooks/pre-commit` fired by a real `git commit`. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-2: the status report does not call an unpublished row recordable":

  test "t_the_status_report_does_not_call_an_unpublished_row_recordable":
    const caseName =
      "t_the_status_report_does_not_call_an_unpublished_row_recordable"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("status-recordable")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      commitLockAndPublish(fx, "a lock that names every sibling's seed")
      let before = readFile(lockPath(fx))

      # Two siblings ahead of their pins; ONE of them pushed. The difference
      # between them is one real `git push` and nothing else.
      let publishedRev = moveAndPublishSibling(fx, "alpha", "a pushed revision")
      let localOnlyRev = moveSibling(fx, "gamma", "a revision that never left")

      # ---- (1) the arrangement is what the case claims -------------------
      check publishedRev != fx.seedSha[0]
      check localOnlyRev != fx.seedSha[2]
      check siblingRevIsPublished(fx, "alpha", publishedRev)
      check not siblingRevIsPublished(fx, "gamma", localOnlyRev)

      let status = flakeStatus(fx, "--json")
      checkpoint("override-status stderr:\n" & status.stderr)
      check status.code == 0
      let doc = parseJson(status.stdout)
      checkpoint("report:\n" & pretty(doc, indent = 2))

      let alphaRow = statusRow(doc, "alpha-src")
      let gammaRow = statusRow(doc, "gamma-src")
      check not alphaRow.isNil
      check not gammaRow.isNil

      if not alphaRow.isNil and not gammaRow.isNil:
        # ---- (2) the DIRECTION axis is untouched -------------------------
        # Both are ahead. A "fix" that demoted the unpublished row to some
        # other relation would satisfy (3) while breaking the report, so the
        # relation is pinned here before the recordability is read.
        check alphaRow["relation"].getStr() == "ahead"
        check gammaRow["relation"].getStr() == "ahead"
        check alphaRow["sibling"].getStr() == publishedRev
        check gammaRow["sibling"].getStr() == localOnlyRev

        # ---- (3) the asymmetry, on the field that predicts the refresh ---
        check alphaRow["recordable"].getBool()
        check not gammaRow["recordable"].getBool()

      # ---- (4) …and the prediction is CHECKED against the refresh -------
      # The report is only worth reading if it agrees with what happens next,
      # so what happens next is run: exactly the row called recordable is the
      # row whose pin moves.
      let committed = tryCommitInApp(fx, "work built against both siblings")
      checkpoint("commit output:\n" & committed.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check committed.code == 0

      let after = readFile(lockPath(fx))
      check nodeText(after, "alpha-src").contains(publishedRev)
      check nodeText(after, "gamma-src").contains(fx.seedSha[2])
      check not after.contains(localOnlyRev)
      # …and the rest of the document is byte-identical, so "the pin moved" is
      # a statement about one node rather than about a rewritten file.
      let alphaBefore = nodeText(before, "alpha-src")
      let alphaAfter = nodeText(after, "alpha-src")
      check alphaBefore.len > 0
      check before.replace(alphaBefore, alphaAfter) == after
