## NF-3 (shell-entry half) — **the §3.2 ambient report reaches shell entry by
## reading the override vector the shell APPLIED, not by re-deriving it.**
##
## Spec: Nix-Flake-Coexistence.md §3.2:
##
##   > **Rule.** A behind-pin sibling is reported **ambiently, at shell entry**,
##   > naming the sibling, the distance, and the command that reconciles it. It
##   > is not an error: deliberately testing an older dependency is legitimate.
##   > It must not be silent: unknowingly testing one is how a green shell
##   > certifies nothing.
##
## ## The gap this closes, and why it is not a second derivation
##
## The report has existed since NF-3 and is correct. What has never worked is
## the delivery: the only route to it is `repro flake override-args`, whose
## cost is dominated by `repro develop --list --all` — measured at ~226 s on
## this workspace — and NF-3's own LANDED notes record that cost as the
## OUTSTANDING blocker on migrating this repository's `.envrc` off the six
## `NIX_FLAKE_OVERRIDE_*` variables and the content-pinned direnv plugin. So
## the warning the spec makes a rule has never actually reached a developer
## here. It arrived instead as a Nim compile error naming a symbol
## (`undeclared identifier: 'EvidenceScope'`) in a repo that was not the stale
## one, four times in one working day, with the pre-push gate as the first
## thing that ever named the real cause.
##
## `--applied` does not re-derive the override set. NF-3 removed a second
## DERIVATION — one that guessed the set from workspace membership, disagreed
## with the exact answer in both directions, and made the pre-push gate fail
## open — and nothing here brings it back. This mode is HANDED the argument
## vector that was spliced into `use flake` and reads the substitutions out of
## it. The vector is not an opinion about what the shell built; it is what the
## shell was told to build. For an `.envrc` that has not migrated it is also
## the ONLY correct answer available, because that `.envrc`'s overrides come
## from the plugin: reporting on the binder's answer instead would be the
## two-derivations error with the halves swapped.
##
## ## What is asserted
##
##   1. a sibling BEHIND its pin is NAMED, with its distance and a reconciling
##      command, and the exit status stays 0 — a warning, never an error;
##   2. the AHEAD and AT rows are classified in the same run, by the same
##      renderer as every other consumer, so the three cannot disagree;
##   3. `--applied` and the DERIVED path produce the same classification for
##      the same siblings. One report, two ways of being told which inputs are
##      in play — and if they ever diverge, this is the case that dies;
##   4. an override naming something that is not a local working tree
##      (`github:…`) is STATED, not silently dropped. "There is no tree here"
##      and "we did not look" must not look alike (NF-1's rule);
##   5. `--applied` with a develop-set selector REFUSES rather than ignoring
##      the selector. §5's whole subject is knobs that were read by nothing;
##   6. an EMPTY applied vector is reported as "this shell substituted nothing",
##      which is explicitly NOT the sentence "nothing has drifted";
##   7. a vector supplied after `--` without `--applied` REFUSES rather than
##      being silently discarded.
##
## ## Mutation
##
## The mutation that kills this case is making `--applied` fall back to the
## derived develop set when the vector is empty: assert (6) then reports on
## inputs the shell did not substitute, which is exactly the OVER-reporting
## half of the derivation NF-3 deleted. Suppressing the behind row at a small
## distance kills assert (1), the regression the milestone names for its
## sibling case `behind_pin_is_never_silent`.
##
## Test-double policy: NO mocks, doubles or fakes. Real bare git origins, real
## `git clone`d checkouts, a real `flake.lock` in nix's on-disk format and the
## real `./build/bin/repro` binary — see the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture

proc appliedVector(fx: Nf2Fixture; names: varargs[string]): string =
  ## The `--override-input` triples a shell entry applies, spelled the way
  ## `flakeSiblingOverrideRef` spells them — a git tree, not a `path:` copy.
  for name in names:
    result.add(" --override-input " & name & "-src git+file://" &
      siblingDir(fx, name))

suite "NF-3: shell entry reports drift over the applied overrides":

  test "t_shell_entry_reports_drift_over_the_applied_overrides":
    const caseName = "t_shell_entry_reports_drift_over_the_applied_overrides"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("applied")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      # alpha AT its pin, beta 2 AHEAD, gamma 3 BEHIND — the same three-state
      # workspace `report_classifies_at_ahead_and_behind` builds, so the two
      # cases are comparable by construction.
      let betaHead = advanceSibling(fx, "beta", 2)
      let gammaPinned = advanceSibling(fx, "gamma", 3)
      discard rewindSibling(fx, "gamma", 3)
      setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned)
      check betaHead.len == 40

      let vector = appliedVector(fx, "alpha", "beta", "gamma")

      # ---- (1) + (2) the three states, over the APPLIED vector -------------
      let applied = flakeStatus(fx, "--applied --" & vector)
      check applied.code == 0
      check applied.stderr.contains("WARNING")
      check applied.stderr.contains("'gamma' (flake input 'gamma-src')")
      check applied.stderr.contains("3 commit(s) BEHIND")
      check applied.stderr.contains("git -C " & siblingDir(fx, "gamma") &
        " merge --ff-only")
      check applied.stderr.contains("'beta' (flake input 'beta-src')")
      check applied.stderr.contains("2 commit(s) AHEAD")
      check applied.stderr.contains("1 at pin, 1 ahead, 1 behind")

      # ---- (3) the applied and the DERIVED paths agree ---------------------
      #
      # Same workspace, same siblings, same pins: the develop-set derivation
      # and the applied vector must classify each input identically. This is
      # the assert that dies if `--applied` ever becomes a second opinion about
      # what the shell built rather than a reading of what it was given.
      proc relations(raw: string): seq[string] =
        for row in parseJson(raw)["rows"]:
          result.add(row["input"].getStr() & "=" &
            row["relation"].getStr() & "/" & $row["behindBy"].getInt() &
            "/" & $row["aheadBy"].getInt())
      let appliedJson = flakeStatus(fx, "--applied --json --" & vector)
      let derivedJson = flakeStatus(fx, "--all --json")
      check appliedJson.code == 0
      check derivedJson.code == 0
      check relations(appliedJson.stdout) == relations(derivedJson.stdout)
      check relations(appliedJson.stdout).len == 3

      # ---- (4) a non-local override is STATED ------------------------------
      let remote = flakeStatus(fx,
        "--applied -- --override-input alpha-src github:example/alpha/abcdef")
      check remote.code == 0
      check remote.stderr.contains("not a sibling substitution")
      check remote.stderr.contains("github:example/alpha/abcdef")
      check remote.stderr.contains("0 substituted input(s)")

      # ---- (5) a selector alongside `--applied` REFUSES --------------------
      let contradiction = flakeStatus(fx, "--applied --only=alpha --" & vector)
      check contradiction.code == 2
      check contradiction.stderr.contains("--only=alpha")
      check contradiction.stderr.contains("contradictory")
      # And it refuses in the words that say WHY, not merely that it refused.
      check contradiction.stderr.contains("inert knob")

      # ---- (6) an EMPTY vector is not "nothing has drifted" ----------------
      let empty = flakeStatus(fx, "--applied --")
      check empty.code == 0
      check empty.stderr.contains("substituted no sibling at all")
      check empty.stderr.contains(
        "not the same statement as 'nothing has drifted'")

      # ---- (7) a vector with no `--applied` REFUSES ------------------------
      let unread = flakeStatus(fx, "--" & vector)
      check unread.code == 2
      check unread.stderr.contains("`--applied` was not given")
      check unread.stderr.contains("Re-run as")
