## HL-11 H1 / H2 — **the recipe and its locks must be consistent**, and an
## inconsistency is refused at commit and at push (Unified-Locking-And-Hooks.md
## §16.3).
##
## * **H1, the lock satisfies the recipe.** A `flake.lock` node whose input
##   `flake.nix` pins by revision is locked at that revision; a `repro.lock`
##   resolution lies inside its `uses:` range, and an exact `uses:` version
##   resolves to the `sourceRevision` its producer's `versions:` entry names.
## * **H2, the two locks agree.** A repository resolved by both a `repro.lock`
##   and a `flake.lock` of one repo is resolved at one revision. Identity is
##   the canonical repository URL, never a name.
##
## WHY. Before this, an inconsistent `flake.lock` was either not reported at
## all (an exact pin nothing overrides is no longer compared with its
## checkout, §16.5) or reported as a stale SIBLING (`flake_lock_stale`), which
## sends the operator to move a checkout that is not the problem. And nothing
## compared the two locks: committing reprobuild's own HL-11 M1, an installed
## hook re-pinned `nim-stackable-hooks` in `repro.lock` to a revision other
## than the one `flake.nix` pins as `nim-stackable-hooks-src`, and nothing
## noticed.
##
## Cases (each one also passes the consistent shape first — a positive
## control, so a refusal cannot come from something else in the fixture):
##
##   * `t_h1_flake_rev_pin_disagreeing_with_lock_refuses` — `flake.nix` pins
##     `beta-src` at R1 and `flake.lock` locks it at R2 (with `original.rev`
##     still R1: the shape a refresh that moved `locked.rev` alone left
##     behind). Refused at commit (nothing committed, nothing staged) and at
##     push, as H1, naming the `flake.nix` line, both revisions, the re-lock
##     command and the edit for an intended upgrade, and never "stale". The
##     consistent pin passes both.
##   * `t_h1_repro_lock_outside_uses_range_refuses` — a `repro.lock` package
##     outside the `uses:` range the recipe states is refused at commit and at
##     push, naming the recipe line, the range and the version. An entry under
##     a `when` arm is NOT checked (the hook does not compile the recipe) and
##     says so in the log. An exact `uses:` version whose producer maps it to
##     another revision than the lock's is refused; one mapped through a tag
##     that resolves to the locked revision passes.
##   * `t_h2_two_locks_disagreeing_on_one_repository_refuses` — `repro.lock`
##     resolves `beta`'s origin under the name `hooks-lib`, `flake.lock`
##     resolves it as `beta-src`. Agreeing, both pass. At different revisions,
##     the commit and the push are refused as H2, naming both files, both
##     names and both revisions. A `repro.lock` entry CALLED `beta-src` that
##     fetches another repository is not compared with the flake input of that
##     name, and repositories only one lock resolves are not compared.
##
## `repro lock update` is NAMED by the messages (it is the one-step upgrade
## command of a later milestone) and is asserted to be named WITHOUT
## backticks, because backticks mark commands that run today. No case runs it.
## The commands that do run today (`nix flake update <input> --flake <dir>`,
## `nix flake lock <dir>`, `repro lock refresh`) are asserted to be backticked.
## nix itself is not run here, for the reason `nf2_flake_lock_fixture.nim`
## gives; the re-lock command was checked by hand with nix 2.32.8 against a
## node with `original.rev = R1`, `locked.rev = R2` under a `flake.nix`
## pinning R1: `nix flake lock` left it unchanged, and `nix flake update
## <input>` re-locked it to R1.
##
## Falsifiability: against the tree before this change, the first case's
## inconsistent commit SUCCEEDS (exit 0) and its push passes, because the
## exactly pinned input is no longer compared with anything; the second and
## third cases' inconsistent commits succeed and their pushes report no
## failure at all.
##
## Test-double policy: NO mocks, doubles or fakes. Real bare origins, real
## clones, real `flake.lock` / `repro.lock` documents in their on-disk shapes,
## the real `./build/bin/repro`, a REAL `.git/hooks/pre-commit` fired by a real
## `git commit` (`installPreCommitDispatch`; see `nf2_flake_lock_fixture.nim`
## for why the hook file is written rather than installed), and the real
## `repro check --mode=pre-push`, invoked as the managed `pre-push` hook
## invokes it.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture
import repro_test_support/reasoned_skip

const
  H1 = "recipe_lock_constraint_violated"
  H2 = "cross_lock_revision_disagreement"

proc lineNumberOf(text, needle: string): int =
  var n = 0
  for line in text.splitLines():
    inc n
    if needle in line: return n
  0

proc failureText(report: JsonNode; property: string): string =
  ## The remediation and evidence of the gate failure ``property``, or "".
  let f = gateFailureOf(report, property)
  if f.isNil: return ""
  f{"remediation"}.getStr() & "\n" & f{"evidence"}.getStr()

proc checkNoConsistencyFailure(gate: tuple[code: int; output: string;
    report: JsonNode]) =
  checkpoint("gate output:\n" & gate.output)
  check not hasGateFailure(gate.report, H1)
  check not hasGateFailure(gate.report, H2)
  check gate.code == 0

proc commitWithoutHook(fx: Nf2Fixture; message: string) =
  ## Commit whatever the working tree holds WITHOUT the pre-commit hook, and
  ## publish it: the bypassed commit path the push gate exists to catch.
  removePreCommitDispatch(fx)
  discard gitIn(fx, fx.app, "add -A")
  discard gitIn(fx, fx.app, "commit -q -m " & q(message))
  publishRepo(fx, fx.app)
  installPreCommitDispatch(fx)

proc stagedText(fx: Nf2Fixture; rel: string): string =
  ## ``rel`` as the index holds it: what a refused commit left staged.
  run(q(fx.gitBin) & " -C " & q(fx.app) & " show " & q(":" & rel)).output

proc lockDepEntry(fx: Nf2Fixture; name, path, origin, rev: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
  "\", coord_kind = \"vcs\", url = \"" & originUrl(fx, origin) &
  "\", ref = \"main\", revision = \"" & rev &
  "\", integrity = \"git-sha1:" & rev &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"\", groups = \"\" }"

proc reproLockText(fx: Nf2Fixture; owner, ownerRev: string;
    deps: openArray[string]; packages = ""): string =
  ## A committed `repro.lock` in the shipped `reprobuild.solved-graph-lock.v2`
  ## shape: the owner's root entry plus ``deps``.
  var all = @[lockDepEntry(fx, owner, ".", owner, ownerRev)]
  for d in deps: all.add(d)
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
  "platform = \"x86_64-linux\"\noptimal = true\n" &
  "inputs_digest = \"h1-h2-fixture\"\nvariants = []\n" &
  "packages = [" & packages & "]\n" &
  "deps = [" & all.join(", ") & "]\n"

proc packageEntry(name, version: string): string =
  "{ name = \"" & name & "\", version = \"" & version & "\", source = \"" &
    name & "\", selection = \"selected\" }"

suite "HL-11 H1 / H2: the recipe and its locks are consistent":

  test "t_h1_flake_rev_pin_disagreeing_with_lock_refuses":
    if not nf3Prerequisites("t_h1_flake_rev_pin_disagreeing_with_lock_refuses"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # `beta-src` is pinned BY REVISION in `flake.nix`, and its lock node
      # starts consistent: original.rev = locked.rev = the pin.
      let fx = setupNf2Fixture("h1-flake", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let pinned = fx.seedSha[1]
      let flakeNix = readFile(fx.app / "flake.nix")
      check ("rev=" & pinned) in flakeNix
      let pinLine = lineNumberOf(flakeNix, "beta-src.url")
      check pinLine > 0

      # ---- positive control: an exact pin with a matching lock passes. ----
      let ok = tryCommitInApp(fx, "consistent exact pin")
      checkpoint(ok.output)
      check ok.code == 0
      publishRepo(fx, fx.app)
      checkNoConsistencyFailure(gatePrePush(fx))

      # ---- the lock moves `locked.rev` alone. ------------------------------
      let other = moveAndPublishSibling(fx, "beta", "revision 2")
      check other != pinned
      # Exactly one byte range changes: the `locked.rev` of `beta-src`. The
      # node keeps `original.rev` (and the recipe its `rev=`) at the pin.
      let consistent = nf2FlakeLockText(fx, fx.seedSha[0], pinned,
        fx.seedSha[2], revPinned = ["beta-src"])
      let lockedField = "\"rev\": \"" & pinned & "\",\n        \"revCount\""
      check consistent.count(lockedField) == 1
      let inconsistent = consistent.replace(lockedField,
        "\"rev\": \"" & other & "\",\n        \"revCount\"")
      # The arrangement, asserted: locked.rev is the new revision and
      # original.rev is still the recipe's pin.
      let doc = parseJson(inconsistent)
      check doc["nodes"]["beta-src"]["locked"]["rev"].getStr() == other
      check doc["nodes"]["beta-src"]["original"]["rev"].getStr() == pinned
      writeFile(lockPath(fx), inconsistent)
      let headBefore = headOf(fx, fx.app)
      let lockBefore = lockInCommit(fx)

      # ---- refused at commit, as H1. ---------------------------------------
      let c = tryCommitInApp(fx, "lock disagrees with the pin")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c.code != 0
      check c.head == headBefore
      check lockInCommit(fx) == lockBefore
      check "H1 (the lock satisfies the recipe)" in c.output
      check (fx.app / "flake.nix" & ":" & $pinLine & " pins input 'beta-src'" &
        " at revision " & pinned) in c.output
      check ("locks it at " & other) in c.output
      # Remedy 1, runnable today: re-lock the input from flake.nix.
      check ("`nix flake update beta-src --flake " & fx.app & "`") in c.output
      # Remedy 2: the intended upgrade, as an edit plus the re-lock command,
      # and the one-step command named WITHOUT backticks.
      check ("change rev=" & pinned & " to rev=" & other) in c.output
      check ("`nix flake lock " & fx.app & "`") in c.output
      check ("repro lock update beta-src --to " & other &
        " (not available yet)") in c.output
      check "`repro lock update" notin c.output
      check "stale" notin c.output.toLowerAscii()
      check "lock-consistency refused: rule=H1 system=flake input=beta-src" in
        preCommitLog(fx)
      # The refused commit's own file stays where the developer left it; the
      # stamp file and flake.lock are staged by the helper's `add -A`, so
      # unstage them before the bypass below decides what it commits.
      discard gitIn(fx, fx.app, "reset -q")

      # ---- refused at push, as H1, never as a stale sibling. --------------
      commitWithoutHook(fx, "bypass the hook")
      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      check gate.code == 2
      check hasGateFailure(gate.report, H1)
      check not hasGateFailure(gate.report, "flake_lock_stale")
      check not hasGateFailure(gate.report, H2)
      let text = failureText(gate.report, H1)
      checkpoint(text)
      check (fx.app / "flake.nix" & ":" & $pinLine) in text
      check pinned in text and other in text
      check ("`nix flake update beta-src --flake " & fx.app & "`") in text
      check ("change rev=" & pinned & " to rev=" & other) in text
      check "stale" notin text.toLowerAscii()

  test "t_h1_repro_lock_outside_uses_range_refuses":
    if not nf3Prerequisites("t_h1_repro_lock_outside_uses_range_refuses"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # `delta` is the repo under test here: it carries no `flake.lock`, so the
      # only lock in play is its `repro.lock`.
      let base = setupNf2Fixture("h1-repro")
      defer: removeDir(base.scratch)
      isolateNf2Config(base)
      defer: releaseNf2Config()
      var fx = base
      fx.app = base.ws / "delta"
      publishAll(base)
      let recipePath = fx.app / "repro.nim"
      proc recipe(range: string; exact = ""): string =
        "import repro_project_dsl\n\n" &
        "package delta:\n" &
        "  uses:\n" &
        "    # the range under test\n" &
        "    \"libfoo " & range & "\"\n" &
        (if exact.len > 0: "    \"beta " & exact & "\"\n" else: "") &
        "    when defined(macosx):\n" &
        "      \"libfoo >=9\"\n"
      let deltaHead = headOf(fx, fx.app)
      writeFile(recipePath, recipe(">=1.0 <2"))
      writeFile(fx.app / "repro.lock", reproLockText(fx, "delta", deltaHead,
        [], packageEntry("libfoo", "1.4.0")))
      installPreCommitDispatch(fx)

      # ---- positive control: the resolution is inside the range. The
      # conditional `libfoo >=9` is NOT checked, and the log says so. -------
      let ok = tryCommitInApp(fx, "consistent range")
      checkpoint(ok.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check ok.code == 0
      check ("lock-consistency not checked: " & recipePath & ":8: " &
        "'libfoo >=9' — under a when/if/case arm") in preCommitLog(fx)
      publishRepo(fx, fx.app)
      let okGate = gatePrePushIn(base, fx.app)
      checkNoConsistencyFailure(okGate)
      # The push gate names the unchecked entry too: silence is not a pass.
      var notices: seq[string]
      if okGate.report.kind == JObject and okGate.report.hasKey("notices"):
        for n in okGate.report["notices"]: notices.add(n.getStr())
      checkpoint("gate notices:\n" & notices.join("\n"))
      check ("recipe/lock consistency not checked: " & recipePath & ":8: " &
        "'libfoo >=9' — under a when/if/case arm") in notices.join("\n")

      # ---- the recipe tightens its range; the lock is not re-solved. ------
      writeFile(recipePath, recipe(">=2.0 <3"))
      let rangeLine = lineNumberOf(readFile(recipePath), "\"libfoo >=2.0 <3\"")
      check rangeLine == 6
      let headBefore = headOf(fx, fx.app)
      let c = tryCommitInApp(fx, "tighten the range")
      checkpoint(c.output)
      check c.code != 0
      check c.head == headBefore
      check ("H1 (the lock satisfies the recipe): " & recipePath & ":" &
        $rangeLine & " requires 'libfoo >=2.0 <3' (uses:), but " &
        fx.app / "repro.lock" & " resolves package 'libfoo' at version " &
        "1.4.0, which that range does not admit") in c.output
      check ("From " & fx.app & " run: `repro lock refresh`") in c.output
      check ("widen the range at " & recipePath & ":" & $rangeLine &
        " so it admits 1.4.0") in c.output
      check "stale" notin c.output.toLowerAscii()
      discard gitIn(fx, fx.app, "reset -q")

      # ---- the same state, pushed past the hook, is refused as H1. --------
      commitWithoutHook(fx, "bypass the hook")
      let gate = gatePrePushIn(base, fx.app)
      checkpoint("gate output:\n" & gate.output)
      check gate.code == 2
      check hasGateFailure(gate.report, H1)
      let text = failureText(gate.report, H1)
      check (recipePath & ":" & $rangeLine & " requires 'libfoo >=2.0 <3'") in
        text
      check "resolves package 'libfoo' at version 1.4.0" in text
      check "rule=H1 system=repro package=libfoo" in text

      # ---- an exact version resolves to its producer's sourceRevision. ----
      # `beta` publishes a recipe whose `versions:` maps 1.0.0 to its seed
      # commit (a literal commit id) and 2.0.0 to a TAG on its second commit.
      let betaDir = base.ws / "beta"
      let betaSeed = base.seedSha[1]
      writeFile(betaDir / "repro.nim",
        "import repro_project_dsl\n\npackage beta:\n  versions:\n" &
        "    \"1.0.0\":\n      sourceRevision = \"" & betaSeed & "\"\n" &
        "    \"2.0.0\":\n      sourceRevision = \"refs/tags/v2.0.0\"\n")
      discard gitIn(base, betaDir, "add -A")
      discard gitIn(base, betaDir, "commit -q -m " & q("beta recipe"))
      let betaTwo = headOf(base, betaDir)
      discard gitIn(base, betaDir, "tag v2.0.0")
      publishRepo(base, betaDir)
      # The lock resolves `beta` at its newest commit, the tagged one.
      writeFile(fx.app / "repro.lock", reproLockText(fx, "delta",
        headOf(fx, fx.app),
        [lockDepEntry(fx, "beta", "../beta", "beta", betaTwo)],
        packageEntry("libfoo", "2.1.0")))
      writeFile(recipePath, recipe(">=2.0 <3", exact = "==1.0.0"))
      let exactLine = lineNumberOf(readFile(recipePath), "\"beta ==1.0.0\"")
      let headExact = headOf(fx, fx.app)
      let e = tryCommitInApp(fx, "beta 1.0.0 against a lock at 2.0.0")
      checkpoint(e.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check e.code != 0
      check e.head == headExact
      check ("H1 (the lock satisfies the recipe): " & recipePath & ":" &
        $exactLine & " requires 'beta ==1.0.0', which " & betaDir /
        "repro.nim" & ":5 maps to sourceRevision " & betaSeed & ", but " &
        fx.app / "repro.lock" & " resolves 'beta' at " & betaTwo) in e.output
      check ("change the 'beta' entry's revision and its git-sha1 integrity " &
        "from " & betaTwo & " to " & betaSeed) in e.output
      check ("repro lock update beta --to " & betaTwo &
        " (not available yet)") in e.output
      discard gitIn(fx, fx.app, "reset -q")
      # 2.0.0 maps to the tag, which resolves to the locked commit: passes.
      writeFile(recipePath, recipe(">=2.0 <3", exact = "==2.0.0"))
      let e2 = tryCommitInApp(fx, "beta 2.0.0 against a lock at 2.0.0")
      checkpoint(e2.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check e2.code == 0
      check "H1 (" notin e2.output

  test "t_h2_two_locks_disagreeing_on_one_repository_refuses":
    if not nf3Prerequisites(
        "t_h2_two_locks_disagreeing_on_one_repository_refuses"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # `flake.nix` pins `beta-src` BY REVISION, so neither commit-time refresh
      # moves it (§16.5) and the two locks stay exactly as each case writes
      # them. `app`'s `repro.lock` resolves `beta`'s origin under ANOTHER
      # name, `hooks-lib`, and `delta`'s origin under the name `beta-src`.
      let fx = setupNf2Fixture("h2", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaSeed = fx.seedSha[1]
      let deltaSeed = fx.seedSha[3]
      let pinLine = lineNumberOf(readFile(fx.app / "flake.nix"),
        "beta-src.url")
      proc appLock(hooksLibRev: string): string =
        reproLockText(fx, "app", headOf(fx, fx.app),
          [lockDepEntry(fx, "hooks-lib", "../beta", "beta", hooksLibRev),
           # Same NAME as the flake input, a DIFFERENT repository: never
           # compared with `beta-src`, although its revision differs.
           lockDepEntry(fx, "beta-src", "../delta", "delta", deltaSeed)])

      # ---- positive control: both locks name the pinned revision. ---------
      writeFile(fx.app / "repro.lock", appLock(betaSeed))
      let ok = tryCommitInApp(fx, "both locks agree")
      checkpoint(ok.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check ok.code == 0
      check betaSeed != deltaSeed
      check "lock-consistency refused" notin preCommitLog(fx)
      # The re-pin ran and added the manifest-declared develop-set siblings the
      # hand-written lock did not carry (`alpha`, `epsilon`): it is the step
      # the refused commit below must NOT apply.
      let committedReproLock = run(q(fx.gitBin) & " -C " & q(fx.app) &
        " show HEAD:repro.lock").output
      check originUrl(fx, "alpha") in committedReproLock
      check originUrl(fx, "epsilon") in committedReproLock
      publishRepo(fx, fx.app)
      checkNoConsistencyFailure(gatePrePush(fx))

      # ---- `repro.lock` moves to another revision of the same repository.
      let betaNext = moveAndPublishSibling(fx, "beta", "revision 2")
      check betaNext != betaSeed
      writeFile(fx.app / "repro.lock", appLock(betaNext))
      let reproLockWritten = readFile(fx.app / "repro.lock")
      let headBefore = headOf(fx, fx.app)
      let reproLockBefore = run(q(fx.gitBin) & " -C " & q(fx.app) &
        " show HEAD:repro.lock").output
      let c = tryCommitInApp(fx, "the two locks disagree")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c.code != 0
      check c.head == headBefore
      check run(q(fx.gitBin) & " -C " & q(fx.app) &
        " show HEAD:repro.lock").output == reproLockBefore
      # The refused commit wrote and staged nothing: the re-pin it planned (it
      # adds the manifest-declared siblings `alpha` and `epsilon`) was not
      # applied, so the file and the index hold exactly what the case wrote.
      check readFile(fx.app / "repro.lock") == reproLockWritten
      check stagedText(fx, "repro.lock") == reproLockWritten
      check ("H2 (the two locks agree): repository ") in c.output
      check (" is resolved by " & fx.app / "repro.lock" & " as 'hooks-lib' " &
        "at " & betaNext & " and by " & fx.app / "flake.lock" &
        " as input 'beta-src' at " & betaSeed & " (pinned by " &
        fx.app / "flake.nix" & ":" & $pinLine & " at " & betaSeed & ")") in
        c.output
      # Both directions of the repair, and the upgrade command, named.
      check ("change the 'hooks-lib' entry's revision and its git-sha1 " &
        "integrity from " & betaNext & " to " & betaSeed) in c.output
      check ("change rev=" & betaSeed & " to rev=" & betaNext) in c.output
      check ("`nix flake lock " & fx.app & "`") in c.output
      check "repro lock update hooks-lib --to <rev> (not available yet)" in
        c.output
      check "`repro lock update" notin c.output
      # Exactly ONE H2 violation: the same-named entry of another repository
      # was not compared.
      check c.output.count("H2 (the two locks agree)") == 1
      check ("as 'beta-src'") notin c.output
      check deltaSeed notin c.output
      check "stale" notin c.output.toLowerAscii()
      discard gitIn(fx, fx.app, "reset -q")

      # ---- the same state, pushed past the hook, is refused as H2. --------
      commitWithoutHook(fx, "bypass the hook")
      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      check gate.code == 2
      check hasGateFailure(gate.report, H2)
      check not hasGateFailure(gate.report, H1)
      check not hasGateFailure(gate.report, "flake_lock_stale")
      let text = failureText(gate.report, H2)
      checkpoint(text)
      check ("repro.lock=hooks-lib@" & betaNext & " flake.lock=beta-src@" &
        betaSeed) in text
      check deltaSeed notin text
