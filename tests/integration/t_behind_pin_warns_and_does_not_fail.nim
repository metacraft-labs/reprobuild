## NF-3 — **behind-pin is a WARNING, never an error: the asymmetry, asserted
## directly.**
##
## Spec: Nix-Flake-Coexistence.md §3.2:
##
##   > A sibling ahead means *you are developing*. A sibling behind almost
##   > always means *your checkout is stale*, not that you chose to downgrade —
##   > so the two warrant different treatment.
##   >
##   > **Rule.** A behind-pin sibling is reported **ambiently, at shell
##   > entry**, naming the sibling, the distance, and the command that
##   > reconciles it. It is not an error: deliberately testing an older
##   > dependency is legitimate. It must not be silent: unknowingly testing one
##   > is how a green shell certifies nothing.
##
## Both halves of that rule are load-bearing and a test asserting only one of
## them is satisfiable by an implementation that gets the other exactly
## backwards, so this case asserts both:
##
##   1. the behind sibling is NAMED, with its DISTANCE and a reconciling
##      command (not silent);
##   2. the exit status is 0 (not an error), so the shell entry that ran it
##      CONTINUES — a legitimate downgrade stays possible;
##   3. and the shell really does continue: `repro flake override-args`, the
##      call `.envrc` splices into `use flake`, still emits the override for
##      the behind sibling and exits 0. This is what "a legitimate downgrade
##      must stay possible" means operationally — the older checkout is still
##      what the dev shell gets.
##
## Assert (3) is not decoration. `override-status` exiting 0 while the shell
## refused to activate would satisfy (2) and still make the downgrade
## impossible, and `.envrc`'s own contract (`|| exit 1` on `override-args`) is
## where that would surface.
##
## ## Mutation (from the milestone): make it an error
##
## ⇒ RED on assert (2). Return 2 from the `override-status` verb when any row
## is `behind`. Note what stays green under that mutation: assert (1), every
## warning string, and the whole of the JSON report — which is exactly why the
## exit status has to be asserted separately rather than inferred from "it
## printed the right thing".
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: behind-pin warns and does not fail":

  test "t_behind_pin_warns_and_does_not_fail":
    const caseName = "t_behind_pin_warns_and_does_not_fail"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("behind-warns")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      # alpha's history gains one revision, the lock records it, and the
      # CHECKOUT is then left one commit behind — a stale checkout, which §3.2
      # says is what "behind" almost always means.
      let alphaNew = advanceSibling(fx, "alpha", 1)
      setFlakePins(fx, alphaNew, fx.seedSha[1], fx.seedSha[2])
      let alphaOld = rewindSibling(fx, "alpha", 1)
      check alphaOld == fx.seedSha[0]
      check alphaOld != alphaNew

      let status = flakeStatus(fx)
      checkpoint("override-status stderr:\n" & status.stderr)

      # ---- (1) named, with the distance and a reconciling command ---------
      check status.stderr.contains("WARNING")
      check status.stderr.contains("'alpha'")
      check status.stderr.contains("flake input 'alpha-src'")
      check status.stderr.contains("1 commit(s) BEHIND")
      check status.stderr.contains("git -C " & siblingDir(fx, "alpha"))
      check status.stderr.contains(alphaNew[0 ..< 12])

      # ---- (2) it is NOT an error -----------------------------------------
      check status.code == 0
      # Said in the message too, so a reader is not left to infer the policy
      # from an exit status they cannot see.
      check status.stderr.contains("This is a warning, not an error")

      # ---- (3) the downgrade stays possible: the shell still activates -----
      let errPath = fx.scratch / "override-args.err"
      let args = run(q(fx.repro) & " flake override-args --all" &
        " --workspace-root=" & q(fx.ws) &
        " --tool-provisioning=path 2>" & q(errPath), cwd = fx.app)
      checkpoint("override-args stdout: " & args.output)
      check args.code == 0
      check args.output.contains("--override-input")
      check args.output.contains("alpha-src")
      check args.output.contains("path:" & siblingDir(fx, "alpha"))
