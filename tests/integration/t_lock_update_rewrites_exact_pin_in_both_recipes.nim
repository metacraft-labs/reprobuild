## HL-11 M4 — **`repro lock update <dependency> [--to <rev>]` is the one
## command for an intended upgrade, in both systems**
## (Unified-Locking-And-Hooks.md §16.4, test obligation §16.7).
##
## WHY. The commit-time re-pin moves lock resolutions only: where a recipe
## constraint excludes the revision a sibling is at, it refuses the commit
## (H3), because an automatic writer cannot know whether the newer checkout is
## an intended upgrade. Before this command the refusal could only describe a
## hand edit of `flake.nix` and a re-lock, and nothing moved `repro.lock` and
## `flake.lock` together. `repro lock update` rewrites an exact pin in
## whichever recipe states it, re-locks a `flake.nix` pin through nix (the
## only thing that computes its `narHash`), moves every resolution of the
## repository, and writes nothing unless everything can be written.
##
## Cases:
##
##   * `t_lock_update_rewrites_exact_pin_in_both_recipes` (the §16.7 case) —
##     `app` pins `beta` exactly in BOTH recipes: `flake.nix` `rev=<betaOne>`
##     and `repro.nim` `uses: "beta ==1.0.0"` (beta's `versions:` maps 1.0.0
##     to betaOne). (A) `repro lock update beta-src --to <betaTwo>` rewrites
##     the `flake.nix` url and the `uses:` version (2.0.0), re-locks the node
##     through the real nix and moves `repro.lock`; every file is asserted
##     byte for byte, nix itself then finds nothing to re-lock, and a real
##     commit and the real pre-push gate pass H1 and H2. (B) With `uses:` a
##     range that admits the target, the range is left alone and the rest
##     moves. (C) A range that excludes the target is refused, naming the
##     line, and nothing is written. (D) A backward target is refused by the
##     regression rule, and passes with `--allow-pin-regression` or
##     `REPRO_ALLOW_PIN_REGRESSION` naming the dependency.
##   * `t_lock_update_refuses_an_ambiguous_name` — one name for two
##     repositories (a flake input and a `repro.lock` dependency) is refused
##     with both candidates and nothing written; the qualified spelling moves
##     only the repository it names.
##   * `t_lock_update_leaves_every_file_when_the_relock_fails` — with no nix
##     on PATH, and with a real nix that cannot fetch the input's url (the
##     origin is moved away after the target was pushed), `flake.nix`, both
##     locks, `repro.nim` and the index are byte-identical afterwards.
##   * `t_lock_update_refuses_an_unpublished_target_for_a_flake_lock` — a
##     target reachable from no remote-tracking ref is refused, for every
##     resolution, when a `flake.lock` resolution would name it: for an exact
##     pin (before nix runs; the printed `git push` runs and the update then
##     succeeds) and for a branch-following input through
##     `refresh-lock --only` (which nothing fetches, so without the rule the
##     unpublished pin would be filed silently). A `repro.lock`-only move is
##     written with a warning naming the push.
##   * `t_lock_update_default_target_refuses_a_dirty_checkout` — the default
##     target (the checkout's HEAD) of a modified checkout is refused, by
##     `repro lock update` and by `refresh-lock --only`, as the per-input
##     refresh refuses it; `--to <commit>` is the stated way past it.
##   * `t_lock_update_moves_every_input_of_one_repository` — two inputs on one
##     repository (one pinned, with comments around it, one following a
##     branch) both move; `flake.nix` changes in that one revision only.
##   * `t_lock_update_converts_an_exact_flake_pin_to_branch_tracking` — the
##     author drops `rev=` from a pinned input's url, leaving the old revision
##     in the node's `original.rev`; ONE `repro lock update` completes the
##     conversion: nix re-locks the node from `flake.nix` (no `original.rev`,
##     a fresh `narHash`), `repro.lock` moves with it, and H1 and H2 pass at
##     commit and at push. A backward target (regression rule) and an
##     unpublished one (publication rule) are refused with every file
##     byte-identical; when the branch tip is not the target, the re-locked
##     node is then moved to the target like any branch-following input.
##     Before this, the command refused such a node and asked for a separate
##     nix re-lock first.
##   * `t_the_h1_and_h2_refusals_lock_update_commands_run` — the backticked
##     `repro lock update` of a real H1 refusal and of a real H2 refusal runs
##     verbatim from the workspace root, and the same commit then passes.
##   * `t_the_h3_refusals_lock_update_command_runs_and_the_commit_succeeds` —
##     the H3 refusal of an overridden exact pin prints `repro lock update …`
##     in backticks; that command, run verbatim from another directory,
##     resolves it, and the same commit then succeeds carrying both locks.
##   * `t_flake_refresh_lock_only_does_what_lock_update_does` — `repro flake
##     refresh-lock` keeps declining an exact pin in a bulk run, and for an
##     input an explicit `--only` names it does what `repro lock update` does.
##
## Falsifiability: before this change `repro lock update` was an unknown verb
## (every case exits 2 with "unknown"), the H1 / H2 / H3 refusals named the
## command "not available yet" without backticks, so their cases find no
## command to run, and `refresh-lock --only=beta` declined the pin (exit 3).
##
## Stand-ins: the no-nix arm runs the real binary with a PATH holding only a
## symlink to the real `git`, which is how "nix is not installed" looks to it;
## the nix-failure arm moves the real bare origin aside, which is how "the
## forge lost the revision" looks to nix. Neither replaces code under test.
##
## Test-double policy: NO mocks, doubles or fakes. Real bare origins and
## clones, the real `./build/bin/repro`, the REAL `nix` (which generates each
## `flake.lock` here and performs every re-lock under test), a real
## `.git/hooks/pre-commit` fired by a real `git commit`
## (`installPreCommitDispatch`; see `nf2_flake_lock_fixture.nim` for why the
## hook file is written rather than installed), the real
## `repro develop --only=beta` and the real `repro check --mode=pre-push`.
## `flake.nix` here declares only the fixture's `git+file://` inputs, so nix
## needs no network: the NF-2 fixture's `nixpkgs` / `flake-utils` inputs are
## dropped by `useNixLockedFlake`, because nix would re-lock them from GitHub.

import std/[json, os, strutils, unittest]

import hl11_two_lock_fixture
import repro_lock
import repro_test_support/reasoned_skip

const
  UpdateLabel = "repro lock update: "
  H1PropertyName = "recipe_lock_constraint_violated"
    ## the pre-push gate property of an H1 violation
  H2PropertyName = "cross_lock_revision_disagreement"
    ## the pre-push gate property of an H2 violation

proc requireNix(): string =
  ## nix is part of the dev shell this suite runs in. Its absence is a broken
  ## environment, not a reason to skip: every case here is about what nix
  ## writes.
  result = findExe("nix")
  if result.len == 0:
    stderr.writeLine("FIXTURE ABORT: `nix` is not on PATH; these cases " &
      "drive the real nix re-lock and cannot run without it")
    quit 1

proc nixIn(dir, args: string): tuple[code: int; output: string] =
  run(q(requireNix()) & " --extra-experimental-features " &
    q("nix-command flakes") & " " & args, cwd = dir)

proc useNixLockedFlake(fx: Nf2Fixture; betaPin: string) =
  ## Replace `app`'s flake with one whose inputs are only the fixture's local
  ## origins, `beta-src` pinned at ``betaPin`` (floating when empty), and let
  ## the REAL `nix flake lock` write its `flake.lock`. Committed past the hook
  ## and published: this is setup, the state a repo is in before the case.
  let pin = if betaPin.len > 0: "&rev=" & betaPin else: ""
  writeFile(fx.app / "flake.nix",
    "{\n" &
    "  description = \"HL-11 M4 fixture consumer\";\n" &
    "\n" &
    "  inputs = {\n" &
    "    alpha-src.url = \"git+" & originUrl(fx, "alpha") & "?ref=main\";\n" &
    "    beta-src.url = \"git+" & originUrl(fx, "beta") & "?ref=main" & pin &
      "\";\n" &
    "    gamma-src.url = \"git+" & originUrl(fx, "gamma") & "?ref=main\";\n" &
    "  };\n" &
    "\n" &
    "  outputs = _: { };\n" &
    "}\n")
  removeFile(lockPath(fx))
  let locked = nixIn(fx.app, "flake lock")
  if locked.code != 0 or not fileExists(lockPath(fx)):
    stderr.writeLine("FIXTURE ABORT: `nix flake lock` failed:\n" &
      locked.output)
    quit 1
  commitWithoutHook(fx, "nix-locked flake")

proc commitBetaRecipe(fx: Nf2Fixture; versions: openArray[(string, string)];
    tagAs: string): string =
  ## Commit a `repro.nim` to `beta` whose `versions:` maps each version to a
  ## tag, tag the new commit ``tagAs``, publish, and return the commit.
  let dir = siblingDir(fx, "beta")
  var text = "import repro_project_dsl\n\npackage beta:\n  versions:\n"
  for (version, tag) in versions:
    text.add("    \"" & version & "\":\n      sourceRevision = \"refs/tags/" &
      tag & "\"\n")
  writeFile(dir / "repro.nim", text)
  discard gitIn(fx, dir, "add -A")
  discard gitIn(fx, dir, "commit -q -m " & q("beta recipe " & tagAs))
  result = headOf(fx, dir)
  discard gitIn(fx, dir, "tag " & tagAs)
  discard gitIn(fx, dir, "push -q origin HEAD:main --tags")

proc appRecipe(usesEntry: string): string =
  "import repro_project_dsl\n\npackage app:\n  uses:\n" &
    "    # the constraint under test\n" &
    "    \"" & usesEntry & "\"\n"

proc writeAppReproLock(fx: Nf2Fixture; betaRev: string) =
  ## `app`'s committed `repro.lock`, resolving beta's origin as `beta`, in the
  ## exact bytes the lock writer serializes (`serializeDepInline` names the
  ## last field `tags`; the shared fixture spells it `groups`, which the
  ## reader ignores). Every writer of this file re-serializes the `deps` line,
  ## so a byte-for-byte expectation must start from the writer's own form.
  writeFile(fx.app / "repro.lock", reproLockText(fx, "app", headOf(fx, fx.app),
    [lockDepEntry(fx, "beta", "../beta", "beta", betaRev)]).replace(
      ", groups = \"\" }", ", tags = \"\" }"))

proc lockUpdate(fx: Nf2Fixture; args: string; env = ""):
    tuple[code: int; output: string] =
  ## The real binary, run from the WORKSPACE root rather than `app`, so the
  ## `--repo-root` every call passes is what selects the repo.
  run(env & q(fx.repro) & " lock update " & args, cwd = fx.ws)

type AppFiles = object
  flakeNix, flakeLock, reproNim, reproLock, tree: string

proc appFiles(fx: Nf2Fixture): AppFiles =
  proc readOr(p: string): string = (if fileExists(p): readFile(p) else: "")
  AppFiles(flakeNix: readOr(fx.app / "flake.nix"),
    flakeLock: readOr(lockPath(fx)), reproNim: readOr(fx.app / "repro.nim"),
    reproLock: readOr(fx.app / "repro.lock"), tree: indexTree(fx))

proc asRewritten(lockText: string): string =
  ## ``lockText`` as a partial lock writer leaves it once it rewrites the
  ## ``deps`` line: the line re-rendered by the current writer (no checkout
  ## ``path``, the self entry marked) and the schema tagged v3 — the rest of
  ## the document byte for byte. The fixture commits a v2 lock, so the first
  ## write migrates it; that is the documented behaviour, not churn.
  var depsLine = ""
  for line in serializeLockedDependencies(
      parseLockedDependencies(lockText)).splitLines():
    if line.startsWith("deps = ["): depsLine = line
  result = lockText
  for line in lockText.splitLines():
    if line.startsWith("deps = ["):
      result = result.replace(line, depsLine)
      break
  result = result.replace("schema = \"" & SolvedGraphLockSchemaV2 & "\"",
    "schema = \"" & SolvedGraphLockSchemaV3 & "\"")

proc checkUnchanged(fx: Nf2Fixture; before: AppFiles) =
  let now = appFiles(fx)
  check now.flakeNix == before.flakeNix
  check now.flakeLock == before.flakeLock
  check now.reproNim == before.reproNim
  check now.reproLock == before.reproLock
  check now.tree == before.tree

proc nodeRev(lockText, node, half: string): string =
  let n = parseJson(lockText)["nodes"][node]{half}
  if n.isNil or n.kind != JObject or n{"rev"}.isNil: "" else: n["rev"].getStr()

proc nodeNarHash(lockText, node: string): string =
  let n = parseJson(lockText)["nodes"][node]{"locked"}
  if n.isNil or n{"narHash"}.isNil: "" else: n["narHash"].getStr()

proc nothingStaged(fx: Nf2Fixture): bool =
  run(q(fx.gitBin) & " -C " & q(fx.app) & " diff --cached --quiet").code == 0

proc checkConsistentAtCommitAndPush(fx: Nf2Fixture; message: string) =
  ## H1 and H2 pass: a real commit through the managed hook, and the real
  ## pre-push gate over it.
  let c = tryCommitInApp(fx, message)
  checkpoint("git commit:\n" & c.output & "\nlog:\n" & preCommitLog(fx))
  check c.code == 0
  check "H1 (" notin c.output
  check "H2 (" notin c.output
  check "REFUSED" notin c.output
  publishRepo(fx, fx.app)
  let gate = gatePrePush(fx)
  checkpoint("gate:\n" & gate.output)
  check not hasGateFailure(gate.report, H1PropertyName)
  check not hasGateFailure(gate.report, H2PropertyName)
  check gate.code == 0

suite "HL-11 M4: repro lock update":

  test "t_lock_update_rewrites_exact_pin_in_both_recipes":
    if not nf3Prerequisites("t_lock_update_rewrites_exact_pin_in_both_recipes"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      discard requireNix()
      let fx = setupNf2Fixture("lu-exact")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaDir = siblingDir(fx, "beta")
      let betaRecipe = betaDir / "repro.nim"
      let betaOne = commitBetaRecipe(fx,
        [("1.0.0", "v1.0.0"), ("2.0.0", "v2.0.0")], "v1.0.0")
      let betaTwo = moveSibling(fx, "beta", "revision 2.0.0")
      discard gitIn(fx, betaDir, "tag v2.0.0")
      discard gitIn(fx, betaDir, "push -q origin HEAD:main --tags")
      check betaOne.len == 40 and betaTwo.len == 40 and betaOne != betaTwo

      # ---- app pins beta exactly in both recipes, at betaOne. -------------
      useNixLockedFlake(fx, betaPin = betaOne)
      writeAppReproLock(fx, betaOne)
      writeFile(fx.app / "repro.nim", appRecipe("beta ==1.0.0"))
      let ok = tryCommitInApp(fx, "pin beta 1.0.0 in both recipes")
      checkpoint(ok.output)
      check ok.code == 0
      publishRepo(fx, fx.app)
      let flakeNixPath = fx.app / "flake.nix"
      let pinLine = lineNumberOf(readFile(flakeNixPath), "beta-src.url")
      check pinLine == 6
      let a0 = appFiles(fx)
      check nodeRev(a0.flakeLock, "beta-src", "locked") == betaOne
      check nodeRev(a0.flakeLock, "beta-src", "original") == betaOne
      let betaUrlBefore = "git+" & originUrl(fx, "beta") & "?ref=main&rev=" &
        betaOne
      let betaUrlAfter = "git+" & originUrl(fx, "beta") & "?ref=main&rev=" &
        betaTwo

      # ---- (A) the exact pin is rewritten in BOTH recipes. ----------------
      let a = lockUpdate(fx, "beta-src --to " & betaTwo & " --repo-root=" &
        q(fx.app))
      checkpoint("lock update (A) -> " & $a.code & "\n" & a.output)
      check a.code == 0
      let a1 = appFiles(fx)
      # flake.nix: exactly the revision in that one url.
      check a1.flakeNix == a0.flakeNix.replace("rev=" & betaOne,
        "rev=" & betaTwo)
      check a1.flakeNix != a0.flakeNix
      # repro.nim: exactly the version of that one uses: entry.
      check a1.reproNim == appRecipe("beta ==2.0.0")
      # repro.lock: exactly beta's revision and integrity.
      check a1.reproLock == a0.reproLock.replace(betaOne, betaTwo)
      check a1.reproLock != a0.reproLock
      # flake.lock: re-locked by nix — both halves of the node, a NEW narHash
      # nix computed — and no other node touched.
      check nodeRev(a1.flakeLock, "beta-src", "locked") == betaTwo
      check nodeRev(a1.flakeLock, "beta-src", "original") == betaTwo
      check nodeNarHash(a1.flakeLock, "beta-src").startsWith("sha256-")
      check nodeNarHash(a1.flakeLock, "beta-src") !=
        nodeNarHash(a0.flakeLock, "beta-src")
      check nodeText(a1.flakeLock, "alpha-src") ==
        nodeText(a0.flakeLock, "alpha-src")
      check nodeText(a1.flakeLock, "gamma-src") ==
        nodeText(a0.flakeLock, "gamma-src")
      # What it says it did, line by line.
      let identity = "_local_" & fx.scratch / "origin-beta"
      check (UpdateLabel & "'beta-src' is repository " & identity &
        "; target " & betaTwo & " (--to)") in a.output.splitLines()
      check (flakeNixPath & ":" & $pinLine & " input 'beta-src': " &
        betaUrlBefore & " -> " & betaUrlAfter) in a.output.splitLines()
      check (fx.app / "repro.nim:6 'beta ==1.0.0' -> 'beta ==2.0.0'") in
        a.output.splitLines()
      check ("flake.lock input 'beta-src': re-locked through nix at " &
        betaTwo) in a.output.splitLines()
      check ("repro.lock 'beta': " & betaOne & " -> " & betaTwo) in
        a.output.splitLines()
      # It leaves the result in the working tree; nothing is staged.
      check nothingStaged(fx)
      # nix agrees with the lock it now holds: re-locking changes nothing.
      let relock = nixIn(fx.app, "flake lock")
      check relock.code == 0
      check readFile(lockPath(fx)) == a1.flakeLock
      # H1 and H2 pass, at commit and at push.
      checkConsistentAtCommitAndPush(fx, "upgrade beta to 2.0.0")

      # ---- (B) a range that admits the target is left alone. --------------
      writeFile(fx.app / "repro.nim", appRecipe("beta >=1.0 <3"))
      let rangeCommit = tryCommitInApp(fx, "beta as a range")
      checkpoint(rangeCommit.output)
      check rangeCommit.code == 0
      publishRepo(fx, fx.app)
      let betaThree = commitBetaRecipe(fx, [("1.0.0", "v1.0.0"),
        ("2.0.0", "v2.0.0"), ("2.1.0", "v2.1.0")], "v2.1.0")
      let line21 = lineNumberOf(readFile(betaRecipe), "\"2.1.0\":")
      check line21 == 9
      let b0 = appFiles(fx)
      let b = lockUpdate(fx, "beta --to " & betaThree & " --repo-root=" &
        q(fx.app))
      checkpoint("lock update (B) -> " & $b.code & "\n" & b.output)
      check b.code == 0
      let b1 = appFiles(fx)
      check b1.reproNim == b0.reproNim
      check b1.flakeNix == b0.flakeNix.replace("rev=" & betaTwo,
        "rev=" & betaThree)
      check b1.reproLock == b0.reproLock.replace(betaTwo, betaThree)
      check nodeRev(b1.flakeLock, "beta-src", "locked") == betaThree
      check nodeRev(b1.flakeLock, "beta-src", "original") == betaThree
      check (fx.app / "repro.nim:6 'beta >=1.0 <3' admits version 2.1.0 (" &
        betaRecipe & ":" & $line21 & " maps " & betaThree & " to it); left " &
        "alone") in b.output.splitLines()
      checkConsistentAtCommitAndPush(fx, "upgrade beta to 2.1.0")

      # ---- (C) a range that excludes the target is refused, with its line.
      let betaFour = commitBetaRecipe(fx, [("1.0.0", "v1.0.0"),
        ("2.0.0", "v2.0.0"), ("2.1.0", "v2.1.0"), ("3.0.0", "v3.0.0")],
        "v3.0.0")
      let line30 = lineNumberOf(readFile(betaRecipe), "\"3.0.0\":")
      check line30 == 11
      let c0 = appFiles(fx)
      let c = lockUpdate(fx, "beta --to " & betaFour & " --repo-root=" &
        q(fx.app))
      checkpoint("lock update (C) -> " & $c.code & "\n" & c.output)
      check c.code == 3
      check (UpdateLabel & fx.app / "repro.nim:6 requires 'beta >=1.0 <3', " &
        "which does not admit version 3.0.0 (" & betaRecipe & ":" & $line30 &
        " maps " & betaFour & " to it). Widening a range is the author's " &
        "decision, so this command does not rewrite it: widen the range at " &
        fx.app / "repro.nim:6 so it admits 3.0.0, then run this again") in
        c.output.splitLines()
      check (UpdateLabel & "nothing was written: every file is as it was") in
        c.output.splitLines()
      checkUnchanged(fx, c0)

      # ---- (D) a backward target needs the regression flag. ---------------
      let d0 = appFiles(fx)
      let d = lockUpdate(fx, "beta --to " & betaTwo & " --repo-root=" &
        q(fx.app))
      checkpoint("lock update (D) -> " & $d.code & "\n" & d.output)
      check d.code == 4
      check (UpdateLabel & "REFUSED: this update would move 2 pinned " &
        "sibling revision(s) BACKWARD. The lock was not written.") in
        d.output.splitLines()
      check (UpdateLabel & "  repro.lock sibling 'beta': behind by 1 " &
        "commit(s) — pinned " & betaThree & ", observed " & betaTwo &
        " (checkout " & betaDir & ")") in d.output.splitLines()
      check (UpdateLabel & "  flake.lock input 'beta-src' (sibling 'beta'): " &
        "behind by 1 commit(s) — pinned " & betaThree & ", observed " &
        betaTwo & " (checkout " & betaDir & ")") in d.output.splitLines()
      check (UpdateLabel & "If the downgrade is deliberate, re-run the " &
        "update naming the sibling(s): `repro lock update beta --to " &
        betaTwo & " --repo-root=" & fx.app & " --allow-pin-regression=" &
        "beta,beta-src` (or set REPRO_ALLOW_PIN_REGRESSION=beta,beta-src)") in
        d.output.splitLines()
      checkUnchanged(fx, d0)
      # …with the flag naming it,
      let d1 = lockUpdate(fx, "beta --to " & betaTwo & " --repo-root=" &
        q(fx.app) & " --allow-pin-regression=beta")
      checkpoint("lock update (D1) -> " & $d1.code & "\n" & d1.output)
      check d1.code == 0
      let afterD1 = appFiles(fx)
      check afterD1.flakeNix == d0.flakeNix.replace("rev=" & betaThree,
        "rev=" & betaTwo)
      check afterD1.reproLock == d0.reproLock.replace(betaThree, betaTwo)
      check nodeRev(afterD1.flakeLock, "beta-src", "locked") == betaTwo
      check afterD1.reproNim == d0.reproNim
      # …or with the variable naming it by its flake input name.
      let d2 = lockUpdate(fx, "beta --to " & betaOne & " --repo-root=" &
        q(fx.app), env = "REPRO_ALLOW_PIN_REGRESSION=beta-src ")
      checkpoint("lock update (D2) -> " & $d2.code & "\n" & d2.output)
      check d2.code == 0
      let afterD2 = appFiles(fx)
      check afterD2.flakeNix == d0.flakeNix.replace("rev=" & betaThree,
        "rev=" & betaOne)
      check afterD2.reproLock == d0.reproLock.replace(betaThree, betaOne)
      check nodeRev(afterD2.flakeLock, "beta-src", "locked") == betaOne
      # The command said the checkout (at betaFour) is not the target: a range
      # does not exempt beta from the commit-time re-pin, which would record
      # the checkout. Following that note, the commit passes H1 and H2.
      check (UpdateLabel & "note: the sibling checkout " & betaDir & " is at " &
        betaFour & ", not " & betaOne & ": unless a recipe pins it exactly, " &
        "the commit-time re-pin records whatever is checked out, so check it " &
        "out at " & betaOne & " before committing (`git -C " & betaDir &
        " checkout " & betaOne & "`)") in d2.output.splitLines()
      discard gitIn(fx, betaDir, "checkout -q " & betaOne)
      checkConsistentAtCommitAndPush(fx, "back to beta 1.0.0")

  test "t_lock_update_refuses_an_ambiguous_name":
    if not nf3Prerequisites("t_lock_update_refuses_an_ambiguous_name"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # The NF-2 flake as it is: `beta-src` floats on beta's origin. app's
      # repro.lock carries a dependency ALSO called `beta-src`, fetching
      # gamma's origin: one name, two repositories.
      let fx = setupNf2Fixture("lu-ambiguous")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let gammaSeed = fx.seedSha[2]
      writeFile(fx.app / "repro.lock", reproLockText(fx, "app",
        headOf(fx, fx.app),
        [lockDepEntry(fx, "beta-src", "../gamma", "gamma", gammaSeed)]))
      commitWithoutHook(fx, "a repro.lock dependency named like an input")
      let newBeta = moveAndPublishSibling(fx, "beta", "revision 2")
      let before = appFiles(fx)
      let r = lockUpdate(fx, "beta-src --to " & newBeta & " --repo-root=" &
        q(fx.app))
      checkpoint("lock update -> " & $r.code & "\n" & r.output)
      check r.code == 2
      check (UpdateLabel & "'beta-src' is AMBIGUOUS: it names 2 things that " &
        "are not one repository — input:beta-src (" & fx.app / "flake.nix" &
        ":6, repository _local_" & fx.scratch / "origin-beta" & "); " &
        "dep:beta-src (" & fx.app / "repro.lock" & ", repository _local_" &
        fx.scratch / "origin-gamma" & "). Name one of them by its qualified " &
        "spelling (input:beta-src, dep:beta-src); nothing was written") in
        r.output.splitLines()
      checkUnchanged(fx, before)
      # The qualified spelling moves only the repository it names: the
      # floating flake input, by the commit refresh's own rewriter; the
      # repro.lock entry of the OTHER repository stays.
      let q1 = lockUpdate(fx, "input:beta-src --to " & newBeta &
        " --repo-root=" & q(fx.app))
      checkpoint("lock update input: -> " & $q1.code & "\n" & q1.output)
      check q1.code == 0
      let after = appFiles(fx)
      check after.reproLock == before.reproLock
      check after.flakeNix == before.flakeNix
      check nodeRev(after.flakeLock, "beta-src", "locked") == newBeta
      # …as a whole node: the `narHash` nix reports for the target, obtained
      # here independently (`nix flake prefetch`), never a `rev`-only node
      # (reprobuild-pm issue 2026-09-27).
      let expected = nixPrefetchedFields(fx, "beta", newBeta)
      if not expected.ok: checkpoint(expected.diagnostic)
      check expected.ok
      check nodeNarHash(after.flakeLock, "beta-src") == expected.narHash
      check nodeNarHash(after.flakeLock, "beta-src") !=
        nodeNarHash(before.flakeLock, "beta-src")
      check nodeText(after.flakeLock, "gamma-src") ==
        nodeText(before.flakeLock, "gamma-src")
      check nodeText(after.flakeLock, "nixpkgs") ==
        nodeText(before.flakeLock, "nixpkgs")

  test "t_lock_update_leaves_every_file_when_the_relock_fails":
    if not nf3Prerequisites(
        "t_lock_update_leaves_every_file_when_the_relock_fails"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      discard requireNix()
      let fx = setupNf2Fixture("lu-atomic")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaSeed = fx.seedSha[1]
      useNixLockedFlake(fx, betaPin = betaSeed)
      writeAppReproLock(fx, betaSeed)
      commitWithoutHook(fx, "repro.lock beside the flake")
      # The target is PUBLISHED as far as this checkout can tell (a real push
      # moved `refs/remotes/origin/main` to it), so the publication rule lets
      # the update reach nix. That is the state these arms need: the failure
      # under test is nix's, after `flake.nix` has already been rewritten.
      let target = moveAndPublishSibling(fx, "beta", "revision 2")
      check siblingRevIsPublished(fx, "beta", target)
      let before = appFiles(fx)
      check before.reproLock.contains(betaSeed)

      # ---- (1) no nix on PATH: refused before anything is written. --------
      # A PATH holding only `git` (the update needs it): the real binary
      # resolves no `nix` and must say so instead of half-applying.
      let gitOnly = fx.scratch / "git-only-bin"
      createDir(gitOnly)
      createSymlink(fx.gitBin, gitOnly / "git")
      let noNix = lockUpdate(fx, "beta-src --repo-root=" & q(fx.app),
        env = "PATH=" & q(gitOnly) & " ")
      checkpoint("lock update (no nix) -> " & $noNix.code & "\n" &
        noNix.output)
      check noNix.code == 1
      check (UpdateLabel & "nix is not on PATH, and re-locking beta-src " &
        "needs it: only nix computes the new narHash") in
        noNix.output.splitLines()
      check (UpdateLabel & "nothing was written: every file is as it was") in
        noNix.output.splitLines()
      checkUnchanged(fx, before)
      check nothingStaged(fx)

      # ---- (2) nix runs and fails: every file is put back. ----------------
      # The origin goes away after the push: the remote-tracking ref still
      # says "published", and nix, which fetches the input's url, cannot.
      let origin = fx.scratch / "origin-beta.git"
      let away = fx.scratch / "origin-beta.git.away"
      moveDir(origin, away)
      # No --to: the target is the sibling checkout's HEAD.
      let r = lockUpdate(fx, "beta-src --repo-root=" & q(fx.app))
      moveDir(away, origin)
      checkpoint("lock update -> " & $r.code & "\n" & r.output)
      check r.code == 1
      check (UpdateLabel & "re-locking beta-src through nix failed (`nix " &
        "flake update beta-src --flake " & fx.app & "`). If " & target &
        " is not yet pushed to the input's url, push it first. nix said:") in
        r.output.splitLines()
      # nix's own words follow, one indented line each, naming the origin it
      # could not fetch.
      var nixSaid: seq[string]
      for line in r.output.splitLines():
        if line.startsWith(UpdateLabel & "  nix: "): nixSaid.add(line)
      checkpoint("nix said: " & $nixSaid)
      check nixSaid.len > 0
      var namesTheOrigin = false
      for line in nixSaid:
        if origin in line: namesTheOrigin = true
      check namesTheOrigin
      check (UpdateLabel & "nothing was written: every file is as it was") in
        r.output.splitLines()
      # flake.nix had been rewritten before nix ran; it is back, byte for
      # byte, with both locks and repro.nim, and nothing is staged.
      checkUnchanged(fx, before)
      check nothingStaged(fx)
      # With the origin back the same command succeeds.
      let again = lockUpdate(fx, "beta-src --repo-root=" & q(fx.app))
      checkpoint("lock update (origin back) -> " & $again.code & "\n" &
        again.output)
      check again.code == 0
      check nodeRev(readFile(lockPath(fx)), "beta-src", "locked") == target
      check readFile(fx.app / "repro.lock") ==
        asRewritten(before.reproLock.replace(betaSeed, target))

  test "t_lock_update_refuses_an_unpublished_target_for_a_flake_lock":
    if not nf3Prerequisites(
        "t_lock_update_refuses_an_unpublished_target_for_a_flake_lock"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # The per-input `flake.lock` refresh never files a revision only this
      # machine has (nix answers HTTP 404 from the forge and nix-direnv falls
      # back to the previous dev shell). `repro lock update`, and
      # `refresh-lock --only` which now delegates to it, keep that rule: a
      # target that would land in flake.lock unpublished is REFUSED, for
      # every resolution, with the push that publishes it. A repro.lock-only
      # move is written, with a warning.
      discard requireNix()
      let fx = setupNf2Fixture("lu-unpublished")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaDir = siblingDir(fx, "beta")
      let betaSeed = fx.seedSha[1]
      useNixLockedFlake(fx, betaPin = betaSeed)
      writeAppReproLock(fx, betaSeed)
      commitWithoutHook(fx, "repro.lock beside the flake")

      # ---- (1) an exact pin: refused before nix, naming the push. ---------
      let local = moveSibling(fx, "beta", "revision 2")
      check not siblingRevIsPublished(fx, "beta", local)
      let before = appFiles(fx)
      let r = lockUpdate(fx, "beta-src --repo-root=" & q(fx.app))
      checkpoint("lock update (unpublished) -> " & $r.code & "\n" & r.output)
      check r.code == 1
      let push = "git -C " & betaDir & " push origin " & local &
        ":refs/heads/main"
      check (UpdateLabel & "the target " & local & " exists ONLY in this " &
        "local checkout: " & local[0 ..< 12] & " is reachable from no " &
        "remote-tracking ref under refs/remotes/ in " & betaDir & ", so a " &
        "pin naming it would name content nobody else can obtain. A " &
        "flake.lock resolution naming it would name content nix cannot " &
        "fetch for anybody else (nix reports HTTP error 404 from the forge, " &
        "and nix-direnv falls back to the previous dev shell instead of " &
        "failing), so the update was refused for every resolution of " &
        "_local_" & fx.scratch / "origin-beta" & ". Publish it first with `" &
        push & "`, then run this again; or, if it is already published and " &
        "this checkout has not seen it, run `git -C " & betaDir &
        " fetch origin` first (publication is judged from local " &
        "remote-tracking refs only, never over the network)") in
        r.output.splitLines()
      check (UpdateLabel & "nothing was written: every file is as it was") in
        r.output.splitLines()
      check "re-locking" notin r.output
      checkUnchanged(fx, before)
      check nothingStaged(fx)
      # The printed push RUNS, and then the same command succeeds.
      check push in backtickedCommands(r.output)
      let pushed = runNamedCommand(fx, push, fx.ws)
      checkpoint("ran `" & push & "` -> " & $pushed.code & "\n" &
        pushed.output)
      check pushed.code == 0
      check siblingRevIsPublished(fx, "beta", local)
      let ok = lockUpdate(fx, "beta-src --repo-root=" & q(fx.app))
      checkpoint("lock update (published) -> " & $ok.code & "\n" & ok.output)
      check ok.code == 0
      check nodeRev(readFile(lockPath(fx)), "beta-src", "locked") == local
      check readFile(fx.app / "repro.lock") ==
        asRewritten(before.reproLock.replace(betaSeed, local))

      # ---- (2) a branch-following input, through `refresh-lock --only`. ---
      # Nothing fetches here (the commit refresh's rewriter moves locked.rev
      # without nix), so without the rule this is where an unpublished pin
      # would be filed silently.
      useNixLockedFlake(fx, betaPin = "")
      writeAppReproLock(fx, local)
      commitWithoutHook(fx, "beta follows main")
      let local2 = moveSibling(fx, "beta", "revision 3")
      check not siblingRevIsPublished(fx, "beta", local2)
      let before2 = appFiles(fx)
      check nodeRev(before2.flakeLock, "beta-src", "locked") == local
      let only = run(q(fx.repro) & " flake refresh-lock --flake=" &
        q(fx.app) & " --workspace-root=" & q(fx.ws) &
        " --tool-provisioning=path --only=beta", cwd = fx.app)
      checkpoint("refresh-lock --only=beta -> " & $only.code & "\n" &
        only.output)
      check only.code == 1
      check ("repro flake refresh-lock: the target " & local2 & " exists " &
        "ONLY in this local checkout") in only.output
      check ("Publish it first with `git -C " & betaDir & " push origin " &
        local2 & ":refs/heads/main`") in only.output
      check ("repro flake refresh-lock: nothing was written: every file is " &
        "as it was") in only.output.splitLines()
      checkUnchanged(fx, before2)

      # ---- (3) repro.lock alone: written, with the warning. ---------------
      removeFile(fx.app / "flake.nix")
      removeFile(lockPath(fx))
      commitWithoutHook(fx, "no flake")
      let before3 = appFiles(fx)
      let r3 = lockUpdate(fx, "beta --repo-root=" & q(fx.app))
      checkpoint("lock update (repro.lock only) -> " & $r3.code & "\n" &
        r3.output)
      check r3.code == 0
      # The revision and integrity move, and `ref` is cleared: a `ref` names
      # a published branch containing the revision, and none contains it yet
      # (the commit-time re-pin records an unpublished HEAD the same way).
      check readFile(fx.app / "repro.lock") ==
        asRewritten(before3.reproLock.replace(local, local2).replace(
          "ref = \"main\", revision = \"" & local2,
          "ref = \"\", revision = \"" & local2))
      check before3.reproLock.count("ref = \"main\", revision = \"" &
        local) == 1
      check (UpdateLabel & "note: the target " & local2 & " exists ONLY in " &
        "this local checkout: " & local2[0 ..< 12] & " is reachable from no " &
        "remote-tracking ref under refs/remotes/ in " & betaDir & ", so a " &
        "pin naming it would name content nobody else can obtain: " &
        fx.app / "repro.lock" & " will name a revision nobody else can " &
        "fetch, and the pre-push gate refuses the push until it is " &
        "published (`git -C " & betaDir & " push origin " & local2 &
        ":refs/heads/main`)") in r3.output.splitLines()
      check nothingStaged(fx)

  test "t_lock_update_default_target_refuses_a_dirty_checkout":
    if not nf3Prerequisites(
        "t_lock_update_default_target_refuses_a_dirty_checkout"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # The per-input refresh never records a modified sibling's HEAD ("a
      # develop-mode dependency with uncommitted modifications does not
      # update a project lock"). The DEFAULT target of `repro lock update`
      # (and so `refresh-lock --only`) is "what the checkout is", so it keeps
      # that rule; an explicit --to names a commit and is not affected.
      discard requireNix()
      let fx = setupNf2Fixture("lu-dirty")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaDir = siblingDir(fx, "beta")
      let betaSeed = fx.seedSha[1]
      useNixLockedFlake(fx, betaPin = betaSeed)
      writeAppReproLock(fx, betaSeed)
      commitWithoutHook(fx, "repro.lock beside the flake")
      let next = moveAndPublishSibling(fx, "beta", "revision 2")
      dirtySibling(fx, "beta")
      let before = appFiles(fx)
      let refused = "the sibling checkout " & betaDir & " has 1 " &
        "uncommitted change(s), so its HEAD " & next & " is not what it " &
        "holds, and a lock must not record it (a develop-mode dependency " &
        "with uncommitted modifications does not update a project lock); " &
        "commit or stash the changes and run this again, or name the " &
        "commit explicitly with --to " & next & "; nothing was written"
      let r = lockUpdate(fx, "beta-src --repo-root=" & q(fx.app))
      checkpoint("lock update (dirty) -> " & $r.code & "\n" & r.output)
      check r.code == 1
      check (UpdateLabel & refused) in r.output.splitLines()
      checkUnchanged(fx, before)
      let only = run(q(fx.repro) & " flake refresh-lock --flake=" &
        q(fx.app) & " --workspace-root=" & q(fx.ws) &
        " --tool-provisioning=path --only=beta", cwd = fx.app)
      checkpoint("refresh-lock --only=beta (dirty) -> " & $only.code & "\n" &
        only.output)
      check only.code == 1
      check ("repro flake refresh-lock: " & refused) in
        only.output.splitLines()
      checkUnchanged(fx, before)
      # Naming the commit explicitly is the stated way past it.
      let explicit = lockUpdate(fx, "beta-src --to " & next &
        " --repo-root=" & q(fx.app))
      checkpoint("lock update --to (dirty) -> " & $explicit.code & "\n" &
        explicit.output)
      check explicit.code == 0
      check nodeRev(readFile(lockPath(fx)), "beta-src", "locked") == next
      check readFile(fx.app / "repro.lock") ==
        asRewritten(before.reproLock.replace(betaSeed, next))

  test "t_lock_update_moves_every_input_of_one_repository":
    if not nf3Prerequisites(
        "t_lock_update_moves_every_input_of_one_repository"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # Two inputs fetch beta's origin: `beta-src` pinned exactly, with a
      # comment on its line, and `beta-tip` following main. Identity is the
      # canonical repository URL, never the name (§16.3), so both are
      # resolutions of ONE repository and §16.4's "every resolution" moves
      # both. The rewrite touches one literal: the pinned url's revision.
      # Every comment, the floating line and the other inputs keep their
      # bytes.
      discard requireNix()
      let fx = setupNf2Fixture("lu-two-inputs")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaSeed = fx.seedSha[1]
      let beta = "git+" & originUrl(fx, "beta") & "?ref=main"
      let flakeText =
        "{\n" &
        "  # Fixture consumer: two inputs on one repository.\n" &
        "  inputs = {\n" &
        "    alpha-src.url = \"git+" & originUrl(fx, "alpha") &
          "?ref=main\";\n" &
        "    # the release pin, kept on purpose\n" &
        "    beta-src.url = \"" & beta & "&rev=" & betaSeed &
          "\"; # pinned\n" &
        "    beta-tip.url = \"" & beta & "\";\n" &
        "    gamma-src.url = \"git+" & originUrl(fx, "gamma") &
          "?ref=main\";\n" &
        "  };\n" &
        "\n" &
        "  outputs = _: { };\n" &
        "}\n"
      writeFile(fx.app / "flake.nix", flakeText)
      removeFile(lockPath(fx))
      let locked = nixIn(fx.app, "flake lock")
      checkpoint(locked.output)
      check locked.code == 0
      commitWithoutHook(fx, "two inputs on beta")
      let next = moveAndPublishSibling(fx, "beta", "revision 2")
      let before = appFiles(fx)
      check nodeRev(before.flakeLock, "beta-src", "locked") == betaSeed
      check nodeRev(before.flakeLock, "beta-tip", "locked") == betaSeed
      let r = lockUpdate(fx, "beta-tip --to " & next & " --repo-root=" &
        q(fx.app))
      checkpoint("lock update -> " & $r.code & "\n" & r.output)
      check r.code == 0
      let after = appFiles(fx)
      # flake.nix: one revision in one literal, every other byte kept.
      check after.flakeNix == flakeText.replace("&rev=" & betaSeed,
        "&rev=" & next)
      check after.flakeNix.count(betaSeed) == 0
      # flake.lock: the pin re-locked by nix, the floating input moved by
      # the refresh's rewriter, alpha and gamma untouched.
      check nodeRev(after.flakeLock, "beta-src", "locked") == next
      check nodeRev(after.flakeLock, "beta-src", "original") == next
      check nodeRev(after.flakeLock, "beta-tip", "locked") == next
      check nodeRev(after.flakeLock, "beta-tip", "original") == ""
      check nodeText(after.flakeLock, "alpha-src") ==
        nodeText(before.flakeLock, "alpha-src")
      check nodeText(after.flakeLock, "gamma-src") ==
        nodeText(before.flakeLock, "gamma-src")
      check (fx.app / "flake.nix:6 input 'beta-src': " & beta & "&rev=" &
        betaSeed & " -> " & beta & "&rev=" & next) in r.output.splitLines()
      check ("flake.lock input 'beta-src': re-locked through nix at " &
        next) in r.output.splitLines()
      check ("flake.lock input 'beta-tip': " & betaSeed & " -> " & next &
        " (follows a branch; ") in r.output
      check nothingStaged(fx)
      checkConsistentAtCommitAndPush(fx, "beta moved in both inputs")

  test "t_lock_update_converts_an_exact_flake_pin_to_branch_tracking":
    if not nf3Prerequisites(
        "t_lock_update_converts_an_exact_flake_pin_to_branch_tracking"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # §16.6's conversion is "replace the exact revision with a branch
      # reference and run `repro lock update <dependency>`": ONE command.
      # Dropping `rev=` from the url leaves the old revision in the node's
      # `original.rev`, which only nix rewrites, so the command re-locks that
      # node through nix itself, then moves it like any branch-following
      # input — with the regression and publication rules and the
      # all-or-nothing snapshot intact.
      discard requireNix()
      let fx = setupNf2Fixture("lu-convert")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaDir = siblingDir(fx, "beta")
      let betaSeed = fx.seedSha[1]
      let betaTwo = moveAndPublishSibling(fx, "beta", "revision 2")
      useNixLockedFlake(fx, betaPin = betaTwo)
      writeAppReproLock(fx, betaTwo)
      let ok = tryCommitInApp(fx, "pin beta at revision 2")
      checkpoint(ok.output)
      check ok.code == 0
      publishRepo(fx, fx.app)
      let flakeNixPath = fx.app / "flake.nix"
      let pinnedFlake = readFile(flakeNixPath)
      check nodeRev(readFile(lockPath(fx)), "beta-src", "original") == betaTwo

      # The author's half of the conversion: the url now follows main.
      let converted = pinnedFlake.replace("&rev=" & betaTwo, "")
      check converted != pinnedFlake
      check "rev=" notin converted
      writeFile(flakeNixPath, converted)
      let s0 = appFiles(fx)
      # The stale state: flake.nix floats, the node still records the pin.
      check nodeRev(s0.flakeLock, "beta-src", "original") == betaTwo
      check nodeRev(s0.flakeLock, "beta-src", "locked") == betaTwo

      # ---- (R) a backward target is refused by the regression rule. -------
      let r = lockUpdate(fx, "beta-src --to " & betaSeed & " --repo-root=" &
        q(fx.app))
      checkpoint("lock update (R) -> " & $r.code & "\n" & r.output)
      check r.code == 4
      check (UpdateLabel & "REFUSED: this update would move 2 pinned " &
        "sibling revision(s) BACKWARD. The lock was not written.") in
        r.output.splitLines()
      check (UpdateLabel & "nothing was written: every file is as it was") in
        r.output.splitLines()
      checkUnchanged(fx, s0)

      # ---- (P) an unpublished target is refused before nix runs. ----------
      let betaThree = moveSibling(fx, "beta", "revision 3")
      check not siblingRevIsPublished(fx, "beta", betaThree)
      let p = lockUpdate(fx, "beta-src --repo-root=" & q(fx.app))
      checkpoint("lock update (P) -> " & $p.code & "\n" & p.output)
      check p.code == 1
      check (UpdateLabel & "the target " & betaThree & " exists ONLY in " &
        "this local checkout: ") in p.output
      check (UpdateLabel & "nothing was written: every file is as it was") in
        p.output.splitLines()
      check "re-locked" notin p.output
      checkUnchanged(fx, s0)

      # ---- (A) one command completes the conversion. ----------------------
      publishSibling(fx, "beta")
      check siblingRevIsPublished(fx, "beta", betaThree)
      let a = lockUpdate(fx, "beta-src --repo-root=" & q(fx.app))
      checkpoint("lock update (A) -> " & $a.code & "\n" & a.output)
      check a.code == 0
      let a1 = appFiles(fx)
      # The recipe stays exactly as the author wrote it.
      check a1.flakeNix == converted
      # flake.lock: nix re-locked the node from flake.nix (no original.rev,
      # a narHash nix computed for the branch tip, which is the target), and
      # no other node changed.
      check nodeRev(a1.flakeLock, "beta-src", "locked") == betaThree
      check nodeRev(a1.flakeLock, "beta-src", "original") == ""
      check parseJson(a1.flakeLock)["nodes"]["beta-src"]{"original"}{
        "ref"}.getStr() == "main"
      check nodeNarHash(a1.flakeLock, "beta-src").startsWith("sha256-")
      check nodeNarHash(a1.flakeLock, "beta-src") !=
        nodeNarHash(s0.flakeLock, "beta-src")
      check nodeText(a1.flakeLock, "alpha-src") ==
        nodeText(s0.flakeLock, "alpha-src")
      check nodeText(a1.flakeLock, "gamma-src") ==
        nodeText(s0.flakeLock, "gamma-src")
      # repro.lock: exactly beta's revision and integrity.
      check a1.reproLock == s0.reproLock.replace(betaTwo, betaThree)
      check a1.reproLock != s0.reproLock
      let identity = "_local_" & fx.scratch / "origin-beta"
      check (UpdateLabel & "'beta-src' is repository " & identity &
        "; target " & betaThree & " (the HEAD of " & betaDir & ")") in
        a.output.splitLines()
      check ("flake.lock input 'beta-src': re-locked through nix from " &
        "flake.nix, which no longer pins a revision (the stale " &
        "original.rev is dropped; the branch resolves to " & betaThree &
        ")") in a.output.splitLines()
      check ("repro.lock 'beta': " & betaTwo & " -> " & betaThree) in
        a.output.splitLines()
      check nothingStaged(fx)
      # nix agrees with the lock it now holds: re-locking changes nothing.
      let relock = nixIn(fx.app, "flake lock")
      check relock.code == 0
      check readFile(lockPath(fx)) == a1.flakeLock
      # H1 and H2 pass, at commit and at push.
      checkConsistentAtCommitAndPush(fx, "track beta through the lock")

      # ---- (F) the branch tip is not the target: re-locked, then moved. ---
      useNixLockedFlake(fx, betaPin = betaThree)
      let betaFour = moveAndPublishSibling(fx, "beta", "revision 4")
      discard gitIn(fx, betaDir, "checkout -q " & betaThree)
      check headOf(fx, betaDir) == betaThree
      let floating = readFile(flakeNixPath).replace("&rev=" & betaThree, "")
      check "rev=" notin floating
      writeFile(flakeNixPath, floating)
      let f0 = appFiles(fx)
      check nodeRev(f0.flakeLock, "beta-src", "original") == betaThree
      let f = lockUpdate(fx, "beta-src --repo-root=" & q(fx.app))
      checkpoint("lock update (F) -> " & $f.code & "\n" & f.output)
      check f.code == 0
      let f1 = appFiles(fx)
      check f1.flakeNix == floating
      check nodeRev(f1.flakeLock, "beta-src", "locked") == betaThree
      check nodeRev(f1.flakeLock, "beta-src", "original") == ""
      check f1.reproLock == f0.reproLock
      check ("flake.lock input 'beta-src': re-locked through nix from " &
        "flake.nix, which no longer pins a revision (the stale " &
        "original.rev is dropped; the branch resolves to " & betaFour &
        ")") in f.output.splitLines()
      check ("flake.lock input 'beta-src': " & betaFour & " -> " &
        betaThree & " (follows a branch; ") in f.output
      checkConsistentAtCommitAndPush(fx, "beta follows main at revision 3")

  test "t_the_h1_and_h2_refusals_lock_update_commands_run":
    if not nf3Prerequisites(
        "t_the_h1_and_h2_refusals_lock_update_commands_run"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # The H1 and H2 refusals print `repro lock update …` in backticks, a
      # promise that it runs where the message is printed. Each is taken out
      # of the real refusal, run verbatim from the workspace root, and the
      # same commit then passes.
      discard requireNix()
      let fx = setupNf2Fixture("lu-h1-h2")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaSeed = fx.seedSha[1]
      let next = moveAndPublishSibling(fx, "beta", "revision 2")
      proc lockUpdateIn(output: string): seq[string] =
        for cmd in backtickedCommands(output):
          if cmd.startsWith("repro lock update "): result.add(cmd)

      # ---- H1: flake.nix pins betaSeed, flake.lock locks next. ------------
      useNixLockedFlake(fx, betaPin = next)
      writeFile(fx.app / "flake.nix", readFile(fx.app / "flake.nix").replace(
        "rev=" & next, "rev=" & betaSeed))
      check nodeRev(readFile(lockPath(fx)), "beta-src", "locked") == next
      let h1 = tryCommitInApp(fx, "the lock disagrees with the pin")
      checkpoint("git commit (H1):\n" & h1.output)
      check h1.code != 0
      check "H1 (the lock satisfies the recipe)" in h1.output
      let h1Cmd = "repro lock update beta-src --to " & next &
        " --repo-root=" & fx.app
      check h1Cmd in lockUpdateIn(h1.output)
      let ran1 = runNamedCommand(fx, h1Cmd, fx.ws)
      checkpoint("ran `" & h1Cmd & "` -> " & $ran1.code & "\n" & ran1.output)
      check ran1.code == 0
      check ("rev=" & next) in readFile(fx.app / "flake.nix")
      check nodeRev(readFile(lockPath(fx)), "beta-src", "original") == next
      checkConsistentAtCommitAndPush(fx, "the lock disagrees with the pin")

      # ---- H2: repro.lock resolves beta at a third revision. --------------
      # The sibling is checked out there, so the commit-time re-pin keeps
      # repro.lock where it is, and the exact flake pin (nothing overrides
      # it) is not compared with the checkout: the disagreement stands.
      let third = moveAndPublishSibling(fx, "beta", "revision 3")
      writeAppReproLock(fx, third)
      let h2 = tryCommitInApp(fx, "the two locks disagree")
      checkpoint("git commit (H2):\n" & h2.output)
      check h2.code != 0
      check "H2 (the two locks agree)" in h2.output
      let toRepro = "repro lock update beta-src --to " & third &
        " --repo-root=" & fx.app
      let toFlake = "repro lock update beta --to " & next &
        " --repo-root=" & fx.app
      check toFlake in lockUpdateIn(h2.output)
      check toRepro in lockUpdateIn(h2.output)
      let ran2 = runNamedCommand(fx, toRepro, fx.ws)
      checkpoint("ran `" & toRepro & "` -> " & $ran2.code & "\n" &
        ran2.output)
      check ran2.code == 0
      check ("rev=" & third) in readFile(fx.app / "flake.nix")
      check nodeRev(readFile(lockPath(fx)), "beta-src", "locked") == third
      check reproLockRevisionOf(readFile(fx.app / "repro.lock"), "beta") ==
        third
      checkConsistentAtCommitAndPush(fx, "the two locks disagree")
      check betaSeed notin readFile(fx.app / "flake.nix")

  test "t_the_h3_refusals_lock_update_command_runs_and_the_commit_succeeds":
    if not nf3Prerequisites(
        "t_the_h3_refusals_lock_update_command_runs_and_the_commit_succeeds"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      discard requireNix()
      let fx = setupNf2Fixture("lu-h3")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      overrideExplicitly(fx, "beta")
      publishAll(fx)
      let betaSeed = fx.seedSha[1]
      useNixLockedFlake(fx, betaPin = betaSeed)
      writeAppReproLock(fx, betaSeed)
      commitWithoutHook(fx, "repro.lock beside the flake")
      let flakeNixPath = fx.app / "flake.nix"
      let pinLine = lineNumberOf(readFile(flakeNixPath), "beta-src.url")
      # The overridden sibling moves past the pin: the commit is refused (H3).
      let betaNext = moveAndPublishSibling(fx, "beta", "revision 2")
      let refused = tryCommitKeepingIndex(fx, "work against the moved beta")
      checkpoint("git commit:\n" & refused.output)
      check refused.code != 0
      check refused.treeAfter == refused.treeBefore
      let command = "repro lock update beta-src --to " & betaNext &
        " --repo-root=" & fx.app
      check ("repro pre-commit: H3 (the commit-time re-pin moves lock " &
        "resolutions, never a recipe constraint): the sibling checkout " &
        siblingDir(fx, "beta") & " is at " & betaNext & ", but " &
        flakeNixPath & ":" & $pinLine & " pins input 'beta-src' at " &
        "revision " & betaSeed & "; the re-pin wrote nothing for this " &
        "repository in either lock (" & fx.app / "repro.lock" & " 'beta' " &
        "stays at " & betaSeed & "; " & fx.app / "flake.lock" & " input " &
        "'beta-src' stays at " & betaSeed & "). (1) If " & betaNext & " is " &
        "the intended upgrade, run `" & command & "`: it changes rev=" &
        betaSeed & " to rev=" & betaNext & " in that input's url in " &
        flakeNixPath & " — the revision is the author's statement and lives " &
        "there, so no refresh can move it — and re-locks the node through " &
        "nix, which is what recomputes its narHash (by hand: make that edit, " &
        "then `nix flake lock " & fx.app & "`, or simply re-enter the dev " &
        "shell); it moves both locks with it, and then commit again.") in
        refused.output
      let commands = backtickedCommands(refused.output)
      checkpoint("backticked: " & $commands)
      check command in commands
      # Run VERBATIM, from the workspace root rather than app: the printed
      # command carries its own --repo-root.
      let ran = runNamedCommand(fx, command, fx.ws)
      checkpoint("ran `" & command & "` -> " & $ran.code & "\n" & ran.output)
      check ran.code == 0
      check ("rev=" & betaNext) in readFile(flakeNixPath)
      check nodeRev(readFile(lockPath(fx)), "beta-src", "locked") == betaNext
      check nodeRev(readFile(lockPath(fx)), "beta-src", "original") == betaNext
      check reproLockRevisionOf(readFile(fx.app / "repro.lock"), "beta") ==
        betaNext
      # The same commit now succeeds, carrying the updated recipe and locks.
      let ok = tryCommitInApp(fx, "work against the moved beta")
      checkpoint("git commit:\n" & ok.output & "\nlog:\n" & preCommitLog(fx))
      check ok.code == 0
      check ("rev=" & betaNext) in committedText(fx, "flake.nix")
      check lockedRevOfNode(committedText(fx, "flake.lock"), "beta-src") ==
        betaNext
      check reproLockRevisionOf(committedText(fx, "repro.lock"), "beta") ==
        betaNext

  test "t_flake_refresh_lock_only_does_what_lock_update_does":
    if not nf3Prerequisites(
        "t_flake_refresh_lock_only_does_what_lock_update_does"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # §16.4: `repro flake refresh-lock` is kept, and for an input it NAMES
      # it does what `repro lock update` does. A bulk run keeps declining an
      # exact pin (exit 3, nothing about the pin written); `--only=beta`
      # rewrites the pin, re-locks it through nix and moves repro.lock too.
      discard requireNix()
      let fx = setupNf2Fixture("lu-refresh-only")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      overrideExplicitly(fx, "beta")
      publishAll(fx)
      let betaSeed = fx.seedSha[1]
      useNixLockedFlake(fx, betaPin = betaSeed)
      writeAppReproLock(fx, betaSeed)
      commitWithoutHook(fx, "repro.lock beside the flake")
      let betaNext = moveAndPublishSibling(fx, "beta", "revision 2")
      let refresh = q(fx.repro) & " flake refresh-lock --flake=" & q(fx.app) &
        " --workspace-root=" & q(fx.ws) & " --tool-provisioning=path"
      # ---- bulk: the exact pin is declined, as before. --------------------
      let before = appFiles(fx)
      let bulk = run(refresh, cwd = fx.app)
      checkpoint("refresh-lock (bulk) -> " & $bulk.code & "\n" & bulk.output)
      check bulk.code == 3
      check "flake.lock NOT refreshed for input 'beta-src'" in bulk.output
      checkUnchanged(fx, before)
      # ---- explicit: the named input is updated in both systems. ----------
      let only = run(refresh & " --only=beta", cwd = fx.app)
      checkpoint("refresh-lock --only=beta -> " & $only.code & "\n" &
        only.output)
      check only.code == 0
      let after = appFiles(fx)
      check after.flakeNix == before.flakeNix.replace("rev=" & betaSeed,
        "rev=" & betaNext)
      check after.reproLock ==
        asRewritten(before.reproLock.replace(betaSeed, betaNext))
      check nodeRev(after.flakeLock, "beta-src", "locked") == betaNext
      check nodeRev(after.flakeLock, "beta-src", "original") == betaNext
      check nodeNarHash(after.flakeLock, "beta-src").startsWith("sha256-")
      check ("repro flake refresh-lock: 'beta' is repository _local_" &
        fx.scratch / "origin-beta" & "; target " & betaNext & " (the HEAD " &
        "of " & siblingDir(fx, "beta") & ")") in only.output.splitLines()
      check nothingStaged(fx)
      checkConsistentAtCommitAndPush(fx, "beta upgraded by refresh-lock")
