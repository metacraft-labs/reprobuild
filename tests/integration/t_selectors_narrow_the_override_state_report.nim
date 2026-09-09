## NF-3 — **the report honours `repro develop`'s selectors, because there is
## only one resolution of the override set and the selectors are what compose
## it.**
##
## Spec: Nix-Flake-Coexistence.md §5, fourth bullet —
##
##   > selection reusing `repro develop`'s vocabulary rather than inventing a
##   > second one, which also closes the all-or-nothing gap in §2
##
## — and §2's third row, which records that the gap is real: `AUTO` is
## all-or-nothing, `repro develop` selects a SET, and "a project mid-transition
## usually wants a *subset* overridden".
##
## ## Why this case exists
##
## An earlier shape resolved the override set TWICE: exactly, through the
## composer, and cheaply, from workspace membership. The cheap derivation was
## the default, and it never saw the selectors at all — `--only=<one repo>`
## and `--except=<one repo>` both reported every substituted input in the
## workspace, `--except` including a warning about the very repo it had been
## told to leave out. Measured on the live workspace, both printed all eight
## rows.
##
## That is not a cosmetic bug. A selector says which repos the shell is
## building from source; a report that ignores it describes a shell that does
## not exist, and reports drift for inputs nix is taking from their pins.
##
## ## What is asserted
##
##   1. `--only=<repo>` reports exactly that repo's input and no other;
##   2. `--except=<repo>` reports every other input and NOT that one — the
##      complement, so a report that simply echoed its argument cannot pass
##      both;
##   3. the ARGUMENTS agree with the report: `override-args --only=<repo>`
##      emits exactly the one `--override-input`, and prints exactly the one
##      drift line beside it. This is the "one resolution" claim in its
##      operative form — the set the shell is given and the set the report
##      describes are the same set, so they cannot disagree about a selector;
##   4. an unselected repo's drift is not mentioned at all: with `--only=alpha`
##      the 3-commits-ahead `beta` produces no line, because nix is building
##      beta from its pin and the pin is right.
##
## ## Mutation
##
## Drop `passthrough` on the way to the composer (resolve the whole lock set
## regardless of what was asked) ⇒ RED on (1), (2) and (4).
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: selectors narrow the override-state report":

  test "t_selectors_narrow_the_override_state_report":
    const caseName = "t_selectors_narrow_the_override_state_report"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("selectors")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      # Two siblings drift, in different amounts, so a report that named the
      # wrong one is distinguishable from one that named none.
      let alphaHead = advanceSibling(fx, "alpha", 2)
      let betaHead = advanceSibling(fx, "beta", 3)
      check alphaHead != fx.seedSha[0]
      check betaHead != fx.seedSha[1]

      # ---- (1) --only names exactly one input -----------------------------
      let only = flakeStatus(fx, "--json --only=alpha")
      check only.code == 0
      let onlyDoc = parseJson(only.stdout)
      checkpoint("--only=alpha report:\n" & pretty(onlyDoc, indent = 2))
      check onlyDoc["rows"].len == 1
      check onlyDoc["rows"][0]["input"].getStr() == "alpha-src"
      check onlyDoc["rows"][0]["relation"].getStr() == "ahead"
      check onlyDoc["rows"][0]["aheadBy"].getInt() == 2
      check onlyDoc["counts"]["ahead"].getInt() == 1

      # ---- (2) --except is its complement ---------------------------------
      let except1 = flakeStatus(fx, "--json --except=alpha")
      check except1.code == 0
      let exceptDoc = parseJson(except1.stdout)
      checkpoint("--except=alpha report:\n" & pretty(exceptDoc, indent = 2))
      check statusRow(exceptDoc, "alpha-src").isNil
      check not statusRow(exceptDoc, "beta-src").isNil
      check not statusRow(exceptDoc, "gamma-src").isNil
      check exceptDoc["rows"].len == 2
      check statusRow(exceptDoc, "beta-src")["aheadBy"].getInt() == 3
      # …and it says nothing at all about the repo it was told to leave out.
      let exceptText = flakeStatus(fx, "--except=alpha")
      checkpoint("--except=alpha stderr:\n" & exceptText.stderr)
      check exceptText.code == 0
      check not exceptText.stderr.contains("'alpha'")

      # ---- (3) the ARGUMENTS agree with the report ------------------------
      let args = flakeArgs(fx, "--only=alpha")
      checkpoint("override-args --only=alpha stdout: " & args.stdout)
      checkpoint("override-args --only=alpha stderr:\n" & args.stderr)
      check args.code == 0
      check args.stdout.contains("--override-input")
      check args.stdout.contains("alpha-src")
      check args.stdout.contains("git+file://" & siblingDir(fx, "alpha"))
      check not args.stdout.contains("beta-src")
      check not args.stdout.contains("gamma-src")
      # The drift report rides along on stderr, from the SAME bindings.
      check args.stderr.contains("'alpha'")
      check args.stderr.contains("2 commit(s) AHEAD")
      check args.stderr.contains("1 substituted input(s)")

      # ---- (4) the unselected sibling's drift is not mentioned ------------
      check not args.stderr.contains("'beta'")
      check not args.stderr.contains("3 commit(s) AHEAD")
      check not only.stdout.contains("beta-src")
