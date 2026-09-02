## NF-3 — **the report classifies at / ahead / behind, each named with its
## distance — and both consumers read THAT report.**
##
## Spec: Nix-Flake-Coexistence.md §5, the third deliverable:
##
##   > a **report** of override state — which inputs are substituted, and for
##   > each, whether the sibling is at, ahead of, or behind its pin — which is
##   > what the ambient shell-entry warning (§3.2) consumes
##
## All three states are constructed in ONE workspace, because that is where a
## classifier can get them confused: alpha is exactly AT its pin, beta is 2
## AHEAD, gamma is 3 BEHIND.
##
## ## What is asserted
##
##   1. every substituted input appears, with its relation and its distance,
##      in the machine-readable report (`--json`);
##   2. the same three classifications appear in the human rendering, each
##      naming its distance — the report and the message cannot disagree,
##      because there is one classifier;
##   3. a `follows`-routed input carries no pin and is classified `unpinned`
##      WITH ITS REASON rather than being dropped, and rather than being
##      called drift. That decision is recorded in `flakeOverrideStateReport`'s
##      header: such an input resolves to another input's node, so "the pin
##      disagrees with the sibling" is not a proposition that can be false
##      about it, and refusing would name a command that cannot help
##      (`refreshFlakeLockText` deliberately declines to move it). It must
##      still be VISIBLE, or "no drift" and "nothing here could be checked"
##      would look alike;
##   4. an input whose node carries a `rev` and NO `narHash` / `lastModified` /
##      `revCount` verifies normally. Those three fields are exactly what
##      NF-2's refresh DELETES from every node whose revision it moved, so a
##      verifier that required them would call every lock NF-2 wrote broken;
##   5. the ARGUMENTS and the REPORT describe the same set. There is one
##      resolution of the override set, so the inputs `override-args` hands the
##      dev shell and the inputs this report classifies are the same inputs —
##      asserted by comparing the two, because "one resolution" is a claim
##      about behaviour and not about code layout;
##   6. the PRE-PUSH GATE, reading the same report, refuses on the ahead row
##      AND on the behind row and says nothing about the `at` row. This is the
##      "two consumers of ONE report" claim, asserted rather than asserted-by-
##      construction.
##
## ## Mutation
##
## The milestone names no mutation for this case; the ones it names for its
## siblings (`suppress when the distance is small`, `make behind an error`,
## `print a command that must be run elsewhere`) all pass through this
## classifier. The mutation recorded against it in the milestone's LANDED table
## is collapsing `behind` into `ahead`, after which the direction is wrong in
## every rendering and asserts (1), (2) and (6) all fail.
##
## Note what this case does NOT kill, and where that is covered instead:
## reporting a `follows`-routed input as drift changes `flakeStateDisagrees`,
## not the classification, so assert (3) — which reads the RELATION — stays
## green under it. The case that dies is
## `a_clean_workspace_pushes_without_a_diagnostic`, whose gate arm then refuses
## a push no command can fix.
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: the report classifies at, ahead and behind":

  test "t_report_classifies_at_ahead_and_behind":
    const caseName = "t_report_classifies_at_ahead_and_behind"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("classify")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      let betaHead = advanceSibling(fx, "beta", 2)
      let gammaPinned = advanceSibling(fx, "gamma", 3)
      let gammaCheckout = rewindSibling(fx, "gamma", 3)
      check gammaCheckout == fx.seedSha[2]
      # alpha: untouched, so the lock's seed pin IS its HEAD.
      setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned)

      # ---- (1) the machine-readable report ---------------------------------
      let js = flakeStatus(fx, "--json")
      check js.code == 0
      let doc = parseJson(js.stdout)
      checkpoint("report:\n" & pretty(doc, indent = 2))

      let atRow = statusRow(doc, "alpha-src")
      check not atRow.isNil
      check atRow["relation"].getStr() == "at"
      check atRow["repo"].getStr() == "alpha"
      check atRow["pinned"].getStr() == fx.seedSha[0]
      check atRow["sibling"].getStr() == fx.seedSha[0]
      check atRow["aheadBy"].getInt() == 0
      check atRow["behindBy"].getInt() == 0

      let aheadRow = statusRow(doc, "beta-src")
      check not aheadRow.isNil
      check aheadRow["relation"].getStr() == "ahead"
      check aheadRow["aheadBy"].getInt() == 2
      check aheadRow["behindBy"].getInt() == 0
      check aheadRow["pinned"].getStr() == fx.seedSha[1]
      check aheadRow["sibling"].getStr() == betaHead

      let behindRow = statusRow(doc, "gamma-src")
      check not behindRow.isNil
      check behindRow["relation"].getStr() == "behind"
      check behindRow["behindBy"].getInt() == 3
      check behindRow["aheadBy"].getInt() == 0
      check behindRow["pinned"].getStr() == gammaPinned
      check behindRow["sibling"].getStr() == gammaCheckout

      check doc["counts"]["at"].getInt() == 1
      check doc["counts"]["ahead"].getInt() == 1
      check doc["counts"]["behind"].getInt() == 1
      check doc["examined"].getBool()

      # ---- (5) the ARGUMENTS and the REPORT describe the same set ----------
      # One resolution: the bindings `override-args` prints are the bindings
      # this report classifies. Asserted both ways — every row has an override
      # and every override has a row — so neither a dropped row nor an extra
      # one can pass.
      let args = flakeArgs(fx, "--all")
      checkpoint("override-args stdout: " & args.stdout)
      check args.code == 0
      for name in ["alpha", "beta", "gamma"]:
        check not statusRow(doc, name & "-src").isNil
        check args.stdout.contains("--override-input " & name & "-src " &
          "path:" & siblingDir(fx, name))
      var overrideCount = 0
      for word in args.stdout.split(" "):
        if word == "--override-input": inc overrideCount
      check overrideCount == doc["rows"].len
      # …and `override-args` prints the SAME drift report beside them, which is
      # what makes `.envrc` one call rather than two.
      check args.stderr.contains("2 commit(s) AHEAD")
      check args.stderr.contains("3 commit(s) BEHIND")
      check args.stderr.contains("1 at pin, 1 ahead, 1 behind")

      # ---- (2) the human rendering, each with its distance ------------------
      let text = flakeStatus(fx)
      checkpoint("override-status stderr:\n" & text.stderr)
      check text.code == 0
      check text.stderr.contains("'beta'")
      check text.stderr.contains("2 commit(s) AHEAD")
      check text.stderr.contains("'gamma'")
      check text.stderr.contains("3 commit(s) BEHIND")
      check text.stderr.contains("1 at pin, 1 ahead, 1 behind")

      # ---- (4) a node with no derived fields verifies normally --------------
      # NF-2's refresh drops `narHash`, `lastModified` and `revCount` from any
      # node whose `rev` it moved. Strip them from alpha's node — the AT row —
      # and the classification must be unchanged.
      var stripped: seq[string]
      for line in readFile(lockPath(fx)).splitLines():
        let t = line.strip()
        if t.startsWith("\"narHash\":") or t.startsWith("\"lastModified\":") or
            t.startsWith("\"revCount\":"):
          continue
        stripped.add(line)
      writeFile(lockPath(fx), stripped.join("\n"))
      check not readFile(lockPath(fx)).contains("narHash")
      let afterStrip = flakeStatus(fx, "--json")
      check afterStrip.code == 0
      let strippedDoc = parseJson(afterStrip.stdout)
      check statusRow(strippedDoc, "alpha-src")["relation"].getStr() == "at"
      check statusRow(strippedDoc, "beta-src")["relation"].getStr() == "ahead"
      check statusRow(strippedDoc, "gamma-src")["relation"].getStr() == "behind"

      # ---- (3) a `follows`-routed input is `unpinned`, with its reason ------
      # Route `beta-src` through a `follows` path — the shape nix writes when
      # one input is told to follow another — so it names no node of its own.
      var lock = parseJson(readFile(lockPath(fx)))
      lock["nodes"]["root"]["inputs"]["beta-src"] = %*["alpha-src"]
      writeFile(lockPath(fx), pretty(lock, indent = 2))
      let follows = flakeStatus(fx, "--json")
      check follows.code == 0
      let followsDoc = parseJson(follows.stdout)
      let followsRow = statusRow(followsDoc, "beta-src")
      check not followsRow.isNil
      check followsRow["relation"].getStr() == "unpinned"
      check followsRow["detail"].getStr().contains("`follows` path")
      check followsDoc["counts"]["unpinned"].getInt() == 1
      # Visible, and not counted as drift.
      let followsText = flakeStatus(fx)
      check followsText.code == 0
      check followsText.stderr.contains("carries no pin to compare")

      # ---- (6) the gate reads the SAME report -------------------------------
      # Restore the lock to the three-state form, then publish everything so
      # the gate's earlier stages pass and this stage is what speaks.
      setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned)
      publishAll(fx)
      commitLockAndPublish(fx, "three-state lock")
      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      check hasGateFailure(gate.report, "flake_lock_stale")
      if hasGateFailure(gate.report, "flake_lock_stale"):
        let evidence =
          gateFailureOf(gate.report, "flake_lock_stale")["evidence"].getStr()
        checkpoint("evidence: " & evidence)
        # The two disagreeing rows, in both directions…
        check evidence.contains("input=beta-src")
        check evidence.contains("relation=ahead")
        check evidence.contains("ahead=2")
        check evidence.contains("input=gamma-src")
        check evidence.contains("relation=behind")
        check evidence.contains("behind=3")
        # …and nothing about the row that agrees.
        check not evidence.contains("input=alpha-src")
