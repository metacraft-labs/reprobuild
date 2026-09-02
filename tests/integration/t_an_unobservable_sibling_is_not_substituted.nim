## NF-3 — **a sibling whose revision cannot be observed is NOT substituted; it
## keeps its `flake.lock` pin, and that is said out loud.**
##
## Spec: Nix-Flake-Coexistence.md §3.3 ("the environment is therefore
## *unreproducible by construction* — not because the inputs are unpinned, but
## because the pins are not the inputs"), §5 (the inert knob), §6 ("both
## environments agree on which revision of each dependency is in play, and both
## say so out loud when they cannot"), and §4's rule that the gate's refusal
## "names a command that runs from where the message is printed" — inherited
## from Unified-Locking-And-Hooks.md §"the named command must RUN where the
## message is printed".
##
## ## The question this decides
##
## A repo in the develop set, carrying a `flake.nix`, whose revision cannot be
## read — the directory is not a git checkout at all, or it is one whose `HEAD`
## cannot be resolved. Two answers were available and only one of them holds
## together:
##
##   * SUBSTITUTE IT ANYWAY. The dev shell then builds a tree whose revision
##     nothing can name. NF-2's commit-path refresh has no revision to record,
##     so `flake.lock` keeps a pin describing something else; NF-3's report has
##     nothing to compare, so it can only say "unknown". If the gate stays
##     quiet, that is §3.1 with the gate's blessing on it. If the gate refuses,
##     the refusal can name no command that fixes it — which arm (4) below
##     MEASURES rather than assumes: `repro flake refresh-lock`, the only verb
##     that writes this lock, exits 0 and leaves the pin alone, so the operator
##     would re-run it forever against a gate that never stops refusing. That
##     is MU1's failure shape, reached by construction instead of by mutation.
##   * DO NOT SUBSTITUTE IT. nix builds the `flake.lock` pin, so the lock DOES
##     describe what was built; the skip is announced with its reason, so "we
##     chose the pin" and "we could not tell" do not look alike; and the state
##     that would have needed an unfixable refusal cannot arise.
##
## The second is implemented: **substituted implies observable**, enforced in
## the single binder, so every consumer inherits it.
##
## ## What is asserted, for BOTH shapes of unobservable
##
## Shape A — a directory that is not a git checkout at all.
## Shape B — a git checkout whose `HEAD` cannot be resolved (a repository with
## no commits yet, which is what a half-finished `git init` leaves behind).
##
##   1. `override-args` does NOT emit an override for it — so nix builds the
##      pin, and `flake.lock` describes what the shell built;
##   2. it is NAMED, with the reason and a remedy, in the same breath as the
##      inputs that WERE substituted;
##   3. the report carries no row for it and the accounting line is short by
##      one — an input that is not substituted is not "at pin", it is absent;
##   4. the pre-push gate does not refuse; and the reason that is right rather
##      than merely quiet is measured in the same arm: the command a refusal
##      would have had to name exits 0 and changes nothing.
##
## ## Mutation
##
## Drop the observability conditions from `flakeBindInputsToCheckouts` (bind on
## `dirExists` + `flake.nix` alone, as the binder did before) ⇒ RED on (1),
## (2) and (3) for both shapes.
##
## Test-double policy: NO mocks, doubles or fakes. The unobservable checkouts
## are made by removing a real `.git` and by a real `git init` with no commit.
## See the headers of `nf2_flake_lock_fixture.nim` and
## `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: an unobservable sibling is not substituted":

  test "t_an_unobservable_sibling_is_not_substituted":
    const caseName = "t_an_unobservable_sibling_is_not_substituted"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("unobservable")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      # `gamma` is the repo used throughout, and deliberately: it is OUTSIDE
      # `app`'s develop-set closure (`depends = "alpha,beta,epsilon"`), so
      # breaking its checkout cannot make an earlier gate stage speak and leave
      # the flake stage untested.
      let gammaPin = fx.seedSha[2]
      check readFile(lockPath(fx)).contains(gammaPin)

      # ==== Shape A: not a git checkout at all =============================
      removeDir(siblingDir(fx, "gamma") / ".git")
      check dirExists(siblingDir(fx, "gamma"))
      check fileExists(siblingDir(fx, "gamma") / "flake.nix")
      check not dirExists(siblingDir(fx, "gamma") / ".git")
      check not fileExists(siblingDir(fx, "gamma") / ".git")

      let argsA = flakeArgs(fx, "--all")
      checkpoint("shape A override-args stdout: " & argsA.stdout)
      checkpoint("shape A override-args stderr:\n" & argsA.stderr)
      check argsA.code == 0
      # ---- (1) it is NOT handed to the dev shell -------------------------
      check not argsA.stdout.contains("gamma-src")
      check not argsA.stdout.contains(siblingDir(fx, "gamma"))
      # …while the observable ones still are, so this is a decision about the
      # unobservable input and not a collapse of the whole answer.
      check argsA.stdout.contains("--override-input alpha-src")
      check argsA.stdout.contains("--override-input beta-src")
      # ---- (2) it is NAMED, with the reason ------------------------------
      check argsA.stderr.contains("NOT substituted: flake input 'gamma-src'")
      check argsA.stderr.contains("is not a git checkout")
      check argsA.stderr.contains("no revision can be observed")
      check argsA.stderr.contains("keeps its flake.lock pin")
      # ---- (3) no row, and the count says so ------------------------------
      let jsA = flakeStatus(fx, "--json")
      check jsA.code == 0
      let docA = parseJson(jsA.stdout)
      checkpoint("shape A report:\n" & pretty(docA, indent = 2))
      check statusRow(docA, "gamma-src").isNil
      check docA["rows"].len == 2
      check docA["counts"]["at"].getInt() == 2
      check docA["counts"]["unknown"].getInt() == 0

      # ---- (4) the gate does not refuse — and that is not mere quiet ------
      publishRepo(fx, fx.app)
      publishRepo(fx, siblingDir(fx, "alpha"))
      publishRepo(fx, siblingDir(fx, "beta"))
      publishRepo(fx, siblingDir(fx, "delta"))
      publishRepo(fx, siblingDir(fx, "epsilon"))
      commitLockAndPublish(fx, "gamma is no longer observable")
      let gate = gatePrePush(fx)
      checkpoint("shape A gate output:\n" & gate.output)
      checkpoint("shape A gate report:\n" & pretty(gate.report, indent = 2))
      check not hasGateFailure(gate.report, "flake_lock_stale")

      # The measurement that makes "do not refuse" the right answer rather than
      # a convenient one: the ONLY command that writes this lock cannot resolve
      # the state a refusal would be complaining about. It exits 0 and leaves
      # gamma's pin exactly where it was, so a gate that refused here would
      # refuse again after the operator did as they were told.
      let before = readFile(lockPath(fx))
      check before.contains(gammaPin)
      let refresh = run(q(fx.repro) & " flake refresh-lock" &
        " --flake=" & q(fx.app) & " --workspace-root=" & q(fx.ws) &
        " --tool-provisioning=path", cwd = fx.app)
      checkpoint("refresh-lock -> " & $refresh.code & "\n" & refresh.output)
      check refresh.code == 0
      check readFile(lockPath(fx)).contains(gammaPin)

      # ==== Shape B: a git checkout whose HEAD cannot be read ==============
      # `git init` with no commit: `.git` exists, so every "is this a git
      # checkout?" test says yes, and `git rev-parse HEAD` still fails.
      discard requireCmd(q(fx.gitBin) & " init -q -b main " &
        q(siblingDir(fx, "gamma")))
      check dirExists(siblingDir(fx, "gamma") / ".git")
      let head = run(q(fx.gitBin) & " -C " & q(siblingDir(fx, "gamma")) &
        " rev-parse HEAD")
      checkpoint("shape B rev-parse HEAD -> " & $head.code & " " & head.output)
      check head.code != 0

      let argsB = flakeArgs(fx, "--all")
      checkpoint("shape B override-args stdout: " & argsB.stdout)
      checkpoint("shape B override-args stderr:\n" & argsB.stderr)
      check argsB.code == 0
      check not argsB.stdout.contains("gamma-src")
      check argsB.stdout.contains("--override-input alpha-src")
      check argsB.stderr.contains("NOT substituted: flake input 'gamma-src'")
      check argsB.stderr.contains("whose HEAD could not be read")
      check argsB.stderr.contains("keeps its flake.lock pin")

      let jsB = flakeStatus(fx, "--json")
      check jsB.code == 0
      let docB = parseJson(jsB.stdout)
      checkpoint("shape B report:\n" & pretty(docB, indent = 2))
      check statusRow(docB, "gamma-src").isNil
      check docB["rows"].len == 2
      check docB["counts"]["unknown"].getInt() == 0

      let gateB = gatePrePushIn(fx, fx.app)
      checkpoint("shape B gate output:\n" & gateB.output)
      check not hasGateFailure(gateB.report, "flake_lock_stale")
      check readFile(lockPath(fx)).contains(gammaPin)
