## NF-3 / CLI check — **`repro check --mode=pre-push` typed by hand reaches the
## verdict the managed hook reaches, about the same commit.**
##
## Spec: CLI/check.md §"Scope: the same verdict by hand and from the hook"
## (decided 2026-10-16): an omitted `--current-repo` defaults to the git
## worktree containing the current directory, and the workspace root is then
## discovered from that repository exactly as the hook discovers it. The
## default does not apply when the current directory is in no git worktree, or
## when `--workspace-root` was given and the worktree lies outside it.
##
## ## The defect this pins
##
## Issue `2026-10-08-no-reprobuild-push-can-pass-the-pre-push-gate-from-this-
## workspace`, its secondary finding: the hook passes
## `--current-repo=<the repository being pushed>`, while a hand run passed
## nothing, took the current directory as the "workspace", and skipped every
## current-repository stage — the `flake.lock` verification among them. So the
## hand run reported only publication and the hook REFUSED the same push. A
## gate whose verdict depends on how it was invoked cannot be used to check a
## push before making it.
##
## ## What is asserted
##
##   1. the gate run the hook's way (`--current-repo=<app>`) refuses a stale
##      `flake.lock` with `flake_lock_stale` (exit 2) — the control that the
##      fixture really is stale;
##   2. the same gate typed by hand in `app`, with NEITHER `--current-repo` NOR
##      `--workspace-root`, refuses with the same failure and the same exit
##      code, and files its report in the workspace the hook files it in;
##   3. likewise from a SUBDIRECTORY of `app` — the default is the worktree's
##      top level, not the directory the operator happens to stand in;
##   4. an explicit `--workspace-root` that CONTAINS the worktree keeps the
##      default, also when it is spelled through a symlink (git reports the
##      resolved path, the operator typed the other one);
##   5. the exclusions hold, and are observed in the report the gate WROTE
##      (its `currentRepo` is empty), not inferred from a missing failure: run
##      from a directory in no git worktree, and run from an unrelated git
##      worktree OUTSIDE the explicit `--workspace-root` — the shape of a test
##      runner standing in its own checkout while it drives a fixture.
##
## The exclusion runs pass no `--pushed-refs`. With refs and no repository the
## gate refuses at the protocol parse before it writes any report (the
## protocol needs a repository to read the object format from), and "no
## `flake_lock_stale` in an empty report" would hold whatever the default did.
##
## ## Mutation
##
## Leave `currentRepo` empty when the flag is omitted (the unfixed behaviour)
## ⇒ RED on (2), (3) and (4): the hand run treats `app` as the workspace and
## never reaches the flake stage. Drop the containment test ⇒ RED on (5b): the
## unrelated checkout becomes the judged repository.
##
## Test-double policy: NO mocks, doubles or fakes. Real git, real bare
## origins, the real `./build/bin/repro`, run as a subprocess with a real
## working directory — the working directory IS the input under test. See the
## headers of `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, unittest]

import repro_test_support/reasoned_skip
import nf3_override_state_fixture

proc handRun(fx: Nf2Fixture; cwd: string; extra = ""; withRefs = true):
    tuple[code: int; output: string; report: JsonNode] =
  ## The gate as an operator types it: no `--current-repo`, no
  ## `--workspace-root` (unless ``extra`` adds one), from ``cwd``. The report
  ## is read from the WORKSPACE's report directory — where the hook files it —
  ## so a hand run that scoped itself to some other directory is caught here
  ## rather than read from wherever it happened to write. ``withRefs = false``
  ## omits `--pushed-refs`; the header says why the exclusion runs need that.
  let path = checkReportPath(fx)
  if fileExists(path): removeFile(path)
  let refsFlag =
    if withRefs: " --pushed-refs=" & q(pushedRefsFile(fx))
    else: ""
  let res = run(q(fx.repro) & " check --mode=pre-push --write-report" &
    refsFlag & " --tool-provisioning=path" & extra, cwd = cwd)
  var report = newJObject()
  if fileExists(path):
    try: report = parseJson(readFile(path))
    except CatchableError: report = newJObject()
  (code: res.code, output: res.output, report: report)

suite "CLI check: a hand-run gate judges the repo the hook judges":

  test "t_a_hand_run_gate_judges_the_repo_the_hook_judges":
    const caseName = "t_a_hand_run_gate_judges_the_repo_the_hook_judges"
    if not nf3Prerequisites(caseName):
      skip("git not on PATH or ./build/bin/repro not built; this case " &
        "drives the real gate over a real git workspace")
    else:
      let fx = setupNf2Fixture("hand-run-scope")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # A stale lock, constructed as the ahead-sibling gate case does: alpha
      # moves two published commits past the revision flake.lock names.
      removePreCommitDispatch(fx)
      let alphaHead = advanceSibling(fx, "alpha", 2)
      check alphaHead != fx.seedSha[0]
      publishAll(fx)
      commitLockAndPublish(fx, "work committed against the newer alpha")

      # ---- (1) the hook's way: the control ----------------------------------
      let hook = gatePrePush(fx)
      checkpoint("hook-way gate output:\n" & hook.output)
      check hook.code == 2
      check hasGateFailure(hook.report, "flake_lock_stale")

      # ---- (2) by hand, from the repository's top level ---------------------
      let top = handRun(fx, fx.app)
      checkpoint("hand run in " & fx.app & " -> " & $top.code & "\n" &
        top.output)
      check top.code == hook.code
      check hasGateFailure(top.report, "flake_lock_stale")

      # ---- (3) by hand, from a subdirectory of it ---------------------------
      # Empty directories are invisible to git, so this leaves the tree clean
      # and the publication stages exactly as they were for (1) and (2).
      let sub = fx.app / "nested" / "deeper"
      createDir(sub)
      let nested = handRun(fx, sub)
      checkpoint("hand run in " & sub & " -> " & $nested.code & "\n" &
        nested.output)
      check nested.code == hook.code
      check hasGateFailure(nested.report, "flake_lock_stale")

      # ---- (4) an explicit root that contains the worktree, via a symlink ---
      let alias = fx.scratch / "ws-alias"
      createSymlink(fx.ws, alias)
      let aliased = handRun(fx, fx.app, " --workspace-root=" & q(alias))
      checkpoint("hand run in " & fx.app & " with --workspace-root=" & alias &
        " -> " & $aliased.code & "\n" & aliased.output)
      check aliased.code == hook.code
      check hasGateFailure(aliased.report, "flake_lock_stale")

      # ---- (5) the exclusions: no default, read from the written report -----
      # (a) a directory in no git worktree.
      let outside = fx.scratch / "not-a-worktree"
      createDir(outside)
      check run(q(fx.gitBin) & " -C " & q(outside) &
        " rev-parse --show-toplevel").code != 0
      let bare = handRun(fx, outside, " --workspace-root=" & q(fx.ws),
        withRefs = false)
      checkpoint("run in " & outside & " -> " & $bare.code & "\n" &
        bare.output)
      check bare.report.hasKey("currentRepo")
      check bare.report{"currentRepo"}.getStr("<absent>") == ""
      check not hasGateFailure(bare.report, "flake_lock_stale")

      # (b) an unrelated git worktree OUTSIDE the explicit workspace root.
      let unrelated = fx.scratch / "unrelated-checkout"
      createDir(unrelated)
      check run(q(fx.gitBin) & " -C " & q(unrelated) & " init -q").code == 0
      let foreign = handRun(fx, unrelated, " --workspace-root=" & q(fx.ws),
        withRefs = false)
      checkpoint("run in " & unrelated & " -> " & $foreign.code & "\n" &
        foreign.output)
      check foreign.report.hasKey("currentRepo")
      check foreign.report{"currentRepo"}.getStr("<absent>") == ""
      check not hasGateFailure(foreign.report, "flake_lock_stale")
