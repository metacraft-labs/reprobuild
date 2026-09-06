## NF-3 — **a workspace whose flake lives in the ROOT repo (`path = "."`) gets
## a report, not a refusal, on every shell entry.**
##
## Spec: Nix-Flake-Coexistence.md §1, first audience — "a project moving to
## Reprobuild whose existing environment is a flake plus `direnv`, which cannot
## stop working during the move". That project's flake is at the top of its own
## repo, and its repo IS the workspace: `repro.lock` names it with
## `path = "."`. It is the smallest and most common shape there is, and it is
## the first one anybody adopting the `.envrc` would hit.
##
## ## The defect this pins
##
## An earlier shape answered the ambient report from workspace MEMBERSHIP, and
## guarded that derivation with "the membership must name the repo this command
## is running in" — a real necessary condition, applied one line too late. The
## loop it was computed in did `if repo.path == ".": continue` FIRST, so a
## membership whose only match WAS the root repo could never satisfy it. Every
## shell entry produced
##
##     the workspace membership at <ws> named 6 repo(s), none of them the repo
##     this command is running in (<ws>) … REFUSING
##
## with exit 2 and a remedy (`repro workspace status`) that cannot help,
## because nothing was wrong.
##
## The membership derivation is gone — there is one resolution of the override
## set now, and it is the develop set — so the guard is gone with it. This case
## is what keeps the shape from regressing: the develop set deliberately
## EXCLUDES the workspace root repo (it is the consumer the set is assembled
## for, not a dependency of it), so any future guard phrased as "the resolved
## set must name this repo" would fail here exactly as the old one did.
##
## ## What is asserted
##
##   1. `repro flake override-status`, run IN the root repo with no `--flake`
##      and no `--workspace-root`, exits 0 and reports the three substituted
##      inputs rather than refusing;
##   2. it says nothing about "not describing this workspace" — the refusal
##      text is named explicitly, so a future refusal with different wording
##      still fails (1) on the exit status;
##   3. the drift it reports is the real drift: the sibling that moved is named
##      with its distance;
##   4. `repro flake override-args`, the call `.envrc` actually makes, emits
##      the overrides from the same place.
##
## ## Mutation
##
## Reinstate a "the resolved set must name the repo this command runs in" guard
## ⇒ RED on (1), (2) and (4).
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: a root-repo flake is reported, not refused":

  test "t_a_root_repo_flake_is_reported_not_refused":
    const caseName = "t_a_root_repo_flake_is_reported_not_refused"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("root-flake")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      # The flake moves to the WORKSPACE ROOT, which the committed `repro.lock`
      # already declares with `path = "."`. That is the single-repo shape: the
      # repo carrying the flake is the workspace, and its dependencies are the
      # siblings beside it.
      copyFile(fx.app / "flake.nix", fx.ws / "flake.nix")
      copyFile(lockPath(fx), fx.ws / "flake.lock")
      check readFile(fx.ws / "repro.lock").contains("path = \".\"")

      let betaHead = advanceSibling(fx, "beta", 4)
      check betaHead != fx.seedSha[1]

      # ---- (1) it reports, from the root repo, with no flags at all --------
      # No `--flake`, no `--workspace-root`: exactly what `.envrc` runs after a
      # `cd`. The workspace is found by the same ascent every other flake verb
      # uses (`.repro/workspace.toml` at `fx.ws`).
      let errPath = fx.scratch / "root-status.err"
      let res = run(q(fx.repro) & " flake override-status 2>" & q(errPath),
        cwd = fx.ws)
      let err = readFile(errPath)
      checkpoint("root-repo override-status stderr:\n" & err)
      check res.code == 0
      check err.contains("3 substituted input(s)")

      # ---- (2) and specifically NOT the old refusal ------------------------
      check not err.contains("not describing this workspace")
      check not err.contains("REFUSING")

      # ---- (3) the drift it reports is the real drift ----------------------
      check err.contains("'beta'")
      check err.contains("4 commit(s) AHEAD")
      check err.contains("2 at pin, 1 ahead, 0 behind")

      # ---- (4) …and the call `.envrc` makes emits the overrides ------------
      let argsErr = fx.scratch / "root-args.err"
      let args = run(q(fx.repro) & " flake override-args --all 2>" &
        q(argsErr), cwd = fx.ws)
      checkpoint("root-repo override-args stdout: " & args.output)
      checkpoint("root-repo override-args stderr:\n" & readFile(argsErr))
      check args.code == 0
      check args.output.contains("--override-input beta-src")
      check args.output.contains("path:" & siblingDir(fx, "beta"))
