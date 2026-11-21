## HL-11 guidance, the soft enforcement (Unified-Locking-And-Hooks.md §16.6).
##
## A repository developed side by side as a workspace sibling is best tracked
## through the locks, and an exact revision in a recipe is legitimate but
## deserves a reason written beside it. Reprobuild carries that guidance in
## WORDS only, never as a refusal:
##
## * **The informational finding.** `repro check` (the pre-push gate) and
##   `repro health` list every exact recipe pin of a workspace sibling, in
##   `flake.nix` and in `repro.nim`, with the file and line and the comment
##   beside the pin, or `no reason stated`. It never changes an exit status.
## * **The sibling line.** An H1, H2 or H3 refusal that concerns an exact pin
##   of a repository with a sibling checkout adds ONE line: the repository is a
##   workspace sibling, the guidelines suggest tracking it through the lock,
##   and the conversion (a branch reference, then `repro lock update
##   <dependency>`, the one command that completes it). Whether the commit or the
##   push is refused does not depend on it: each H1 / H2 case refuses the
##   SAME state twice, with the sibling checked out and with the checkout
##   moved out of the workspace, and asserts the two refusals are identical
##   apart from that one line.
##
## Cases:
##
##   * `t_sibling_exact_pin_is_an_informational_finding` — `app`'s `flake.nix`
##     pins `beta-src` (a comment above it) and `gamma-src` (no comment) by
##     revision, and its `repro.nim` pins `delta ==1.0.0` (a trailing comment),
##     which `delta`'s `versions:` maps to a tag. Positive controls in the same
##     recipes: a floating sibling input (`alpha-src`) and an exact pin of a
##     repository nobody has checked out (`outside-src`) are NOT listed. The
##     gate passes (exit 0, no failure) and lists exactly the three pins, in
##     its text and its JSON report; `repro health --json` lists the same
##     three in an `ok` row, which therefore adds no failure.
##   * `t_an_h1_refusal_carries_the_sibling_line_only_with_a_sibling_checkout`
##     — H1 at commit and at push; also the configurable guideline pointer
##     (`REPRO_DEPENDENCY_GUIDELINES_URL`), and the conversion the line names,
##     carried out (drop the `rev=`, then run the printed `repro lock update`
##     verbatim — the ONLY command the line names), after which `flake.lock`
##     records no `original.rev` and the commit passes.
##   * `t_an_h2_refusal_carries_the_sibling_line_only_with_a_sibling_checkout`
##     — H2 at commit and at push.
##   * `t_an_h3_refusal_carries_the_sibling_line` — the §16.4 commit refusal.
##     It has no "without a sibling" arm, by construction: an H3 refusal is
##     about the revision a sibling CHECKOUT is at, so without one there is no
##     observed revision and nothing to refuse.
##
## Falsifiability: against the tree before this change the gate report has no
## `findings`, `repro health` has no `sibling-exact-pins` row, and no refusal
## carries a `Guidance:` line, so every case fails on its first guidance
## assertion; the two-arm comparisons then fail as well.
##
## Test-double policy: NO mocks, doubles or fakes. Real bare origins, real
## clones, real `flake.lock` / `repro.lock` documents in their on-disk shapes,
## the real `./build/bin/repro`, a real `.git/hooks/pre-commit` fired by a real
## `git commit` (see `nf2_flake_lock_fixture.nim` for why the hook file is
## written rather than installed), the real `repro check --mode=pre-push` as
## the managed `pre-push` hook invokes it, and the real `repro health`.

import std/[json, os, strutils, unittest]

import hl11_two_lock_fixture
import repro_test_support/reasoned_skip

const
  H1 = "recipe_lock_constraint_violated"
  H2 = "cross_lock_revision_disagreement"
  Prefix = "repro pre-commit: "
  GuidanceMark = "Guidance: "
  DefaultPointer = "see your organisation's dependency guidelines"

proc guidanceLine(sibling, checkout, conversion, dependency, repoRoot,
    pointer: string): string =
  ## The §16.6 line exactly as the refusal must print it (without the hook's
  ## `repro pre-commit: ` prefix).
  GuidanceMark & "'" & sibling & "' is a workspace sibling (checked out at " &
    checkout & "); the dependency guidelines suggest tracking a sibling " &
    "through the lock rather than an exact recipe pin (" & pointer &
    "). To convert, " & conversion & "; then run `repro lock update " &
    dependency & " --repo-root=" & repoRoot & "`."

proc flakeConversion(input, root: string): string =
  "in flake.nix, replace the exact revision in input '" & input & "''s url " &
    "with a branch reference"

proc refusalLines(output: string): seq[string] =
  ## Every line the `pre-commit` hook printed, except the guidance line: what
  ## must be identical with and without a sibling checkout.
  for line in output.splitLines():
    if line.startsWith(Prefix) and
        not line.startsWith(Prefix & GuidanceMark):
      result.add(line)

proc withoutGuidance(output: string): seq[string] =
  ## EVERY line the commit printed (the hook's and git's own), minus the one
  ## guidance line: the two arms must agree on all of it, not only on the
  ## lines carrying the hook's prefix.
  for line in output.splitLines():
    if GuidanceMark notin line: result.add(line)

proc guidanceLines(output: string): seq[string] =
  for line in output.splitLines():
    if GuidanceMark in line: result.add(line)

proc failureRemediation(report: JsonNode; property: string): string =
  let f = gateFailureOf(report, property)
  if f.isNil: "" else: f{"remediation"}.getStr()

proc failureProperties(report: JsonNode): seq[string] =
  ## The gate's failure set, in order: identical in both arms.
  let fs = report{"failures"}
  if not fs.isNil and fs.kind == JArray:
    for f in fs: result.add(f{"property"}.getStr())

proc moveCheckoutAway(fx: Nf2Fixture; name: string): string =
  ## Take the sibling checkout out of the workspace (the membership still
  ## declares it), so the repository has NO sibling checkout. Returns where it
  ## went, for ``bringCheckoutBack``.
  result = fx.scratch / (name & "-moved-away")
  moveDir(siblingDir(fx, name), result)
  doAssert not dirExists(siblingDir(fx, name))

proc bringCheckoutBack(fx: Nf2Fixture; name, movedTo: string) =
  moveDir(movedTo, siblingDir(fx, name))
  doAssert dirExists(siblingDir(fx, name))

suite "HL-11 §16.6: guidance, never a refusal":

  test "t_sibling_exact_pin_is_an_informational_finding":
    if not nf3Prerequisites("t_sibling_exact_pin_is_an_informational_finding"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("hl11-finding",
        revPinned = ["beta-src", "gamma-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      let betaSeed = fx.seedSha[1]
      let gammaSeed = fx.seedSha[2]

      # ---- `delta` publishes a recipe whose versions: maps 1.0.0 to a tag.
      let deltaDir = siblingDir(fx, "delta")
      writeFile(deltaDir / "repro.nim",
        "import repro_project_dsl\n\npackage delta:\n  versions:\n" &
        "    \"1.0.0\":\n      sourceRevision = \"refs/tags/d1\"\n")
      discard gitIn(fx, deltaDir, "add -A")
      discard gitIn(fx, deltaDir, "commit -q -m " & q("delta recipe"))
      let deltaOne = headOf(fx, deltaDir)
      discard gitIn(fx, deltaDir, "tag d1")
      discard gitIn(fx, deltaDir, "push -q origin HEAD:main --tags")

      # ---- app's recipes: two flake pins of siblings (one with a reason),
      # a floating sibling input, an exact pin of a repository with no
      # checkout, and an exact repro.nim pin of a sibling with a reason. ----
      let flakePath = fx.app / "flake.nix"
      let outsideRev = "0123456789abcdef0123456789abcdef01234567"
      var flake = readFile(flakePath)
      flake = flake.replace("    beta-src.url",
        "    # Held at the 1.x wire format until app migrates.\n" &
        "    beta-src.url")
      flake = flake.replace("    nixpkgs.url",
        "    outside-src.url = \"github:example-org/outside/" & outsideRev &
        "\";\n    nixpkgs.url")
      writeFile(flakePath, flake)
      let betaLine = lineNumberOf(flake, "beta-src.url")
      let gammaLine = lineNumberOf(flake, "gamma-src.url")
      check betaLine > 0 and gammaLine > 0
      check lineNumberOf(flake, "# Held at the 1.x") == betaLine - 1
      let recipePath = fx.app / "repro.nim"
      let recipe = "import repro_project_dsl\n\npackage app:\n  uses:\n" &
        "    \"delta ==1.0.0\"  # the 1.x protocol; 2.x needs a migration\n"
      writeFile(recipePath, recipe)
      let deltaLine = lineNumberOf(recipe, "delta ==1.0.0")
      writeFile(fx.app / "repro.lock", reproLockText(fx, "app",
        headOf(fx, fx.app),
        [lockDepEntry(fx, "delta", "../delta", "delta", deltaOne)]))
      let ok = tryCommitInApp(fx, "pins with and without reasons")
      checkpoint(ok.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check ok.code == 0
      publishAll(fx)

      # ---- the gate passes, and lists exactly the three sibling pins. -----
      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      check gate.code == 0
      check gate.report{"failures"}.len == 0
      check gate.report{"exitCode"}.getInt(-1) == 0
      let betaMsg = flakePath & ":" & $betaLine & " pins input 'beta-src' " &
        "at " & betaSeed & ", an exact recipe pin of workspace sibling " &
        "'beta' (checked out at " & siblingDir(fx, "beta") & "); reason: " &
        "Held at the 1.x wire format until app migrates."
      let gammaMsg = flakePath & ":" & $gammaLine & " pins input " &
        "'gamma-src' at " & gammaSeed & ", an exact recipe pin of workspace " &
        "sibling 'gamma' (checked out at " & siblingDir(fx, "gamma") &
        "); no reason stated"
      let deltaMsg = recipePath & ":" & $deltaLine & " pins dependency " &
        "'delta' at " & deltaOne & ", an exact recipe pin of workspace " &
        "sibling 'delta' (checked out at " & deltaDir & "); reason: the " &
        "1.x protocol; 2.x needs a migration"
      let findings = gate.report{"findings"}
      check not findings.isNil and findings.kind == JArray
      if not findings.isNil and findings.kind == JArray:
        check findings.len == 3
        var messages: seq[string]
        for f in findings: messages.add(f{"message"}.getStr())
        check messages == @[betaMsg, gammaMsg, deltaMsg]
        if findings.len == 3:
          let b = findings[0]
          check b{"kind"}.getStr() == "sibling-exact-recipe-pin"
          check b{"consumer"}.getStr() == fx.app
          check b{"dependency"}.getStr() == "beta-src"
          check b{"system"}.getStr() == "flake"
          check b{"sibling"}.getStr() == "beta"
          check b{"checkout"}.getStr() == siblingDir(fx, "beta")
          check b{"file"}.getStr() == flakePath
          check b{"line"}.getInt() == betaLine
          check b{"revision"}.getStr() == betaSeed
          check b{"reason"}.getStr() ==
            "Held at the 1.x wire format until app migrates."
          check b{"reasonStated"}.getBool() == true
          check findings[1]{"reason"}.getStr() == ""
          check findings[1]{"reasonStated"}.getBool() == false
          check findings[2]{"system"}.getStr() == "repro"
          check findings[2]{"dependency"}.getStr() == "delta"
          check findings[2]{"file"}.getStr() == recipePath
          check findings[2]{"line"}.getInt() == deltaLine
      # The text form prints each finding as one informational line.
      for m in [betaMsg, gammaMsg, deltaMsg]:
        check ("repro check: info: " & m) in gate.output.splitLines()
      # Positive controls: the floating sibling input and the pin of a
      # repository nobody checked out are not findings.
      # (`$` on a nil JsonNode segfaults, hence the guard: a missing report
      # must fail the assertions above, not take the process down here.)
      let findingsText = if findings.isNil: "" else: $findings
      check "alpha-src" notin findingsText
      check "outside-src" notin findingsText
      check outsideRev notin gate.output

      # ---- `repro health` lists the same three, in an `ok` row. ----------
      let health = run(q(fx.repro) & " health --json --workspace-root=" &
        q(fx.ws), cwd = fx.ws)
      checkpoint("health:\n" & health.output)
      var doc = newJObject()
      try:
        doc = parseJson(health.output)
      except CatchableError:
        checkpoint("health printed no JSON document")
      var row: JsonNode = nil
      var failedRows = 0
      if doc.kind == JObject and doc.hasKey("checks"):
        for c in doc["checks"]:
          if c{"name"}.getStr() == "sibling-exact-pins": row = c
          if c{"status"}.getStr() == "fail": inc failedRows
      check not row.isNil
      if not row.isNil:
        check row{"status"}.getStr() == "ok"
        check row{"remedy"}.getStr() == ""
        check row{"detail"}.getStr() == "3 exact recipe pin(s) of " &
          "workspace siblings (informational; the dependency guidelines " &
          "suggest tracking a sibling through the lock, " & DefaultPointer &
          "): " & betaMsg & "; " & gammaMsg & "; " & deltaMsg
      # The row adds no failure: the exit status is decided by the other rows
      # alone (`failed` counts `fail` rows, and ours is `ok`).
      check doc{"failed"}.getInt(-1) == failedRows
      check health.code == (if failedRows > 0: 1 else: 0)

  test "t_an_h1_refusal_carries_the_sibling_line_only_with_a_sibling_checkout":
    if not nf3Prerequisites(
        "t_an_h1_refusal_carries_the_sibling_line_only_with_a_sibling_checkout"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("hl11-line-h1", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      delEnv("REPRO_DEPENDENCY_GUIDELINES_URL")
      publishAll(fx)
      let pinned = fx.seedSha[1]
      let ok = tryCommitInApp(fx, "consistent exact pin")
      check ok.code == 0
      check guidanceLines(ok.output).len == 0
      publishRepo(fx, fx.app)

      # The lock moves `locked.rev` alone (the H1 shape of
      # t_h1_flake_rev_pin_disagreeing_with_lock_refuses).
      let other = moveAndPublishSibling(fx, "beta", "revision 2")
      let consistent = nf2FlakeLockText(fx, fx.seedSha[0], pinned,
        fx.seedSha[2], revPinned = ["beta-src"])
      let lockedField = "\"rev\": \"" & pinned & "\",\n        \"revCount\""
      check consistent.count(lockedField) == 1
      writeFile(lockPath(fx), consistent.replace(lockedField,
        "\"rev\": \"" & other & "\",\n        \"revCount\""))
      let line = Prefix & guidanceLine("beta", siblingDir(fx, "beta"),
        flakeConversion("beta-src", fx.app), "beta-src", fx.app, DefaultPointer)

      # ---- with the sibling checked out: refused, plus the line. ---------
      let withSib = tryCommitInApp(fx, "lock disagrees with the pin")
      checkpoint("with the sibling:\n" & withSib.output)
      check withSib.code != 0
      check "H1 (the lock satisfies the recipe)" in withSib.output
      check guidanceLines(withSib.output) == @[line]
      # The line follows the H1 paragraph it belongs to.
      let lines = withSib.output.splitLines()
      let at = lines.find(line)
      check at > 0 and lines[at - 1].startsWith(Prefix & "H1 (")
      discard gitIn(fx, fx.app, "reset -q")

      # ---- the pointer is configurable. ----------------------------------
      putEnv("REPRO_DEPENDENCY_GUIDELINES_URL",
        "https://guidelines.example.invalid/revisions")
      let configured = tryCommitInApp(fx, "lock disagrees with the pin")
      delEnv("REPRO_DEPENDENCY_GUIDELINES_URL")
      check configured.code == withSib.code
      check guidanceLines(configured.output) == @[Prefix & guidanceLine("beta",
        siblingDir(fx, "beta"), flakeConversion("beta-src", fx.app), "beta-src", fx.app,
        "see https://guidelines.example.invalid/revisions")]
      check refusalLines(configured.output) == refusalLines(withSib.output)
      check withoutGuidance(configured.output) ==
        withoutGuidance(withSib.output)
      discard gitIn(fx, fx.app, "reset -q")

      # ---- without a sibling checkout: the same refusal, no line. --------
      let movedTo = moveCheckoutAway(fx, "beta")
      let noSib = tryCommitInApp(fx, "lock disagrees with the pin")
      checkpoint("without the sibling:\n" & noSib.output)
      check noSib.code == withSib.code
      check guidanceLines(noSib.output).len == 0
      check refusalLines(noSib.output) == refusalLines(withSib.output)
      check refusalLines(noSib.output).len > 0
      check withoutGuidance(noSib.output) == withoutGuidance(withSib.output)
      check withSib.output.splitLines().len ==
        noSib.output.splitLines().len + 1
      discard gitIn(fx, fx.app, "reset -q")

      # ---- at push: the same failure, with and without the line. ---------
      commitWithoutHook(fx, "bypass the hook")
      let gateNoSib = gatePrePush(fx)
      bringCheckoutBack(fx, "beta", movedTo)
      let gateSib = gatePrePush(fx)
      checkpoint("gate with the sibling:\n" & gateSib.output)
      checkpoint("gate without the sibling:\n" & gateNoSib.output)
      check gateSib.code == 2 and gateNoSib.code == 2
      check hasGateFailure(gateSib.report, H1)
      check hasGateFailure(gateNoSib.report, H1)
      check failureProperties(gateSib.report) ==
        failureProperties(gateNoSib.report)
      let remNoSib = failureRemediation(gateNoSib.report, H1)
      check remNoSib.len > 0
      check GuidanceMark notin remNoSib
      check failureRemediation(gateSib.report, H1) ==
        remNoSib & " " & line[Prefix.len .. ^1]

      # ---- the conversion the line names, carried out. -------------------
      # Replace the exact revision with the branch reference the url already
      # names, then run the line's one command VERBATIM: `repro lock update`
      # re-locks the node through nix (dropping the `original.rev` the pin
      # left in it) and moves it to the checkout. The commit then passes.
      # nix is part of the dev shell this suite runs in; its absence is a
      # broken environment, and the case says so.
      if findExe("nix").len == 0:
        checkpoint("FIXTURE ABORT: `nix` is not on PATH; the conversion " &
          "the guidance line names re-locks through nix")
        fail()
      else:
        let flakePath = fx.app / "flake.nix"
        writeFile(flakePath,
          readFile(flakePath).replace("&rev=" & pinned, ""))
        check ("rev=") notin readFile(flakePath)
        let commands = backtickedCommands(line)
        let update = "repro lock update beta-src --repo-root=" & fx.app
        check commands == @[update]
        let ran = runNamedCommand(fx, update, fx.ws)
        checkpoint("ran `" & update & "` -> " & $ran.code & "\n" & ran.output)
        check ran.code == 0
        let convertedLock = readFile(lockPath(fx))
        check lockedRevOfNode(convertedLock, "beta-src") == other
        let betaOriginal = parseJson(convertedLock)["nodes"]["beta-src"]{
          "original"}
        check not betaOriginal.isNil and betaOriginal{"rev"}.isNil
        check ("\"rev\": \"" & pinned & "\"") notin convertedLock
        let converted = tryCommitInApp(fx, "track beta through the lock")
        checkpoint(converted.output)
        check converted.code == 0
        check guidanceLines(converted.output).len == 0

  test "t_an_h2_refusal_carries_the_sibling_line_only_with_a_sibling_checkout":
    if not nf3Prerequisites(
        "t_an_h2_refusal_carries_the_sibling_line_only_with_a_sibling_checkout"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("hl11-line-h2", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      delEnv("REPRO_DEPENDENCY_GUIDELINES_URL")
      publishAll(fx)
      let betaSeed = fx.seedSha[1]
      proc appLock(rev: string): string =
        reproLockText(fx, "app", headOf(fx, fx.app),
          [lockDepEntry(fx, "hooks-lib", "../beta", "beta", rev)])
      writeFile(fx.app / "repro.lock", appLock(betaSeed))
      let ok = tryCommitInApp(fx, "both locks agree")
      checkpoint(ok.output)
      check ok.code == 0
      check guidanceLines(ok.output).len == 0
      publishRepo(fx, fx.app)

      # `repro.lock` resolves beta's repository (as `hooks-lib`) elsewhere.
      let betaNext = moveAndPublishSibling(fx, "beta", "revision 2")
      writeFile(fx.app / "repro.lock", appLock(betaNext))
      let line = Prefix & guidanceLine("beta", siblingDir(fx, "beta"),
        flakeConversion("beta-src", fx.app), "hooks-lib", fx.app, DefaultPointer)

      let withSib = tryCommitInApp(fx, "the two locks disagree")
      checkpoint("with the sibling:\n" & withSib.output)
      check withSib.code != 0
      check withSib.output.count("H2 (the two locks agree)") == 1
      check guidanceLines(withSib.output) == @[line]
      let lines = withSib.output.splitLines()
      let at = lines.find(line)
      check at > 0 and lines[at - 1].startsWith(Prefix & "H2 (")
      discard gitIn(fx, fx.app, "reset -q")

      let movedTo = moveCheckoutAway(fx, "beta")
      let noSib = tryCommitInApp(fx, "the two locks disagree")
      checkpoint("without the sibling:\n" & noSib.output)
      check noSib.code == withSib.code
      check guidanceLines(noSib.output).len == 0
      check refusalLines(noSib.output) == refusalLines(withSib.output)
      check refusalLines(noSib.output).len > 0
      check withoutGuidance(noSib.output) == withoutGuidance(withSib.output)
      check withSib.output.splitLines().len ==
        noSib.output.splitLines().len + 1
      discard gitIn(fx, fx.app, "reset -q")

      commitWithoutHook(fx, "bypass the hook")
      let gateNoSib = gatePrePush(fx)
      bringCheckoutBack(fx, "beta", movedTo)
      let gateSib = gatePrePush(fx)
      checkpoint("gate with the sibling:\n" & gateSib.output)
      checkpoint("gate without the sibling:\n" & gateNoSib.output)
      check gateSib.code == 2 and gateNoSib.code == 2
      check hasGateFailure(gateSib.report, H2)
      check hasGateFailure(gateNoSib.report, H2)
      check failureProperties(gateSib.report) ==
        failureProperties(gateNoSib.report)
      let remNoSib = failureRemediation(gateNoSib.report, H2)
      check remNoSib.len > 0
      check GuidanceMark notin remNoSib
      check failureRemediation(gateSib.report, H2) ==
        remNoSib & " " & line[Prefix.len .. ^1]

  test "t_an_h3_refusal_carries_the_sibling_line":
    if not nf3Prerequisites("t_an_h3_refusal_carries_the_sibling_line"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("hl11-line-h3", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      delEnv("REPRO_DEPENDENCY_GUIDELINES_URL")
      overrideExplicitly(fx, "beta")
      let betaSeed = fx.seedSha[1]
      writeFile(fx.app / "repro.lock", reproLockText(fx, "app",
        headOf(fx, fx.app), [lockDepEntry(fx, "beta", "../beta", "beta",
        betaSeed)]))
      publishAll(fx)
      let ok = tryCommitInApp(fx, "pinned and at the pin")
      checkpoint(ok.output)
      check ok.code == 0
      check guidanceLines(ok.output).len == 0
      publishRepo(fx, fx.app)

      let betaNext = moveAndPublishSibling(fx, "beta", "revision 2")
      let c = tryCommitInApp(fx, "work against the moved beta")
      checkpoint(c.output)
      check c.code != 0
      let line = Prefix & guidanceLine("beta", siblingDir(fx, "beta"),
        flakeConversion("beta-src", fx.app), "beta-src", fx.app, DefaultPointer)
      check guidanceLines(c.output) == @[line]
      let lines = c.output.splitLines()
      let at = lines.find(line)
      check at > 0 and lines[at - 1].startsWith(Prefix & "H3 (")
      check ("is at " & betaNext) in lines[at - 1]
