## HL-11 M5 — **a bulk develop selection does not substitute an exact recipe
## pin; an explicit one does; and one develop override can be dropped**
## (Unified-Locking-And-Hooks.md §16.4, "Temporary local debugging uses
## develop-mode overrides").
##
## WHY. A recipe that pins a dependency by exact revision says "this revision,
## not whatever is checked out". `repro develop --all` used to record a develop
## override for every repo of the lock set, exact pins included, and the
## managed hooks then treated those pins as overridden: a sibling checkout that
## had moved on (a branch switch, a pull) made the next commit refuse over a
## dependency nobody had asked to substitute. The flake override verb's
## automatic mode (`repro flake override-args --all`, which `useFlakeDevShell`
## runs on every shell entry) likewise built the pinned input from the
## checkout. And when the refusal was right — an explicit experiment moved past
## the pin — the only way back it could offer was to edit the override file by
## hand.
##
## Cases:
##
##   * `t_bulk_develop_skips_exact_recipe_pins` — two workspaces. In one,
##     `app/flake.nix` pins `beta-src` with `rev=`; in the other,
##     `app/repro.nim` pins `alpha ==1.0.0`, which `alpha`'s `versions:` maps
##     to a revision. In each: `repro develop --all` (and `--dry-run`, `--list`,
##     `--json`) skips the pinned dependency and lists it as `pinned by recipe
##     at <file>:<line>`, recording an override for every other node and none
##     for it; the sibling then moves past the pin and a commit is neither
##     refused nor re-pinned for it. Positive control: `repro develop
##     --only=<dependency>` does substitute it (adopted, recorded with the
##     explicit provenance), and the same move then refuses the commit (H3).
##   * `t_flake_override_args_automatic_mode_skips_exact_recipe_pins` —
##     `repro flake override-args --all` (the automatic mode
##     `useFlakeDevShell` calls) emits no `--override-input` for `beta-src` and
##     names it as pinned by recipe, in text and JSON; `--only=beta` emits it,
##     and so does `--all` once `repro develop --only=beta` has recorded an
##     explicit override.
##   * `t_a_legacy_bulk_override_does_not_substitute_an_exact_pin` — the
##     migration rule. Overrides written before provenance told a bulk
##     selection from an explicit one (`provenance = "repro develop --all"`,
##     which `--only` wrote too, and an entry with no provenance) are read as
##     bulk: the hooks do not compare the pinned siblings (the commit passes),
##     and `--list` shows them `pinned` and names the ignored entries.
##     Re-running `repro develop --only=beta` records the explicit provenance,
##     after which the hooks compare `beta` (and refuse), and only `beta`.
##   * `t_the_h3_refusals_drop_command_runs_and_the_commit_succeeds` — the H3
##     refusal's experiment remedy prints a backticked `repro develop --drop=…`;
##     it is taken out of the real refusal and run verbatim from the directory
##     the commit ran in. It removes exactly the overrides of that dependency
##     — the workspace entry and a per-project entry recorded under the flake
##     input's name for the same checkout (the hooks match either) — and no
##     other, and the same commit then succeeds with `flake.lock` left at the
##     pin. Running it again is a reported no-op.
##
## Falsifiability: against the tree before this change, `repro develop --all`
## adopts and records the pinned sibling (no `pinned-by-recipe`), so the later
## commit is REFUSED as H3 in both workspaces; `override-args --all` emits
## `--override-input beta-src`; the legacy entries make the hooks compare and
## refuse at the first commit; and `--drop` is an unsupported flag while the
## refusal names no runnable drop command.
##
## Test-double policy: NO mocks, doubles or fakes. Real bare origins, real
## clones, real `flake.nix` / `flake.lock` / `repro.lock` / `repro.nim`
## documents in their on-disk shapes, the real `./build/bin/repro` for every
## verb, a REAL `.git/hooks/pre-commit` fired by a real `git commit`
## (`installPreCommitDispatch`; `nf2_flake_lock_fixture.nim` says why the hook
## file is written rather than installed), and the real `repro check
## --mode=pre-push`. The legacy override file of the migration case is written
## by hand in the exact shape the previous `repro develop` serialiser wrote,
## because the binary that wrote it is the one this change replaces. nix itself
## is not run, for the reason `nf2_flake_lock_fixture.nim` gives: these cases
## assert on what the verbs print and on what the commit carries.

import std/[json, os, strutils, unittest]

import hl11_two_lock_fixture
import repro_test_support/reasoned_skip

const H3Head = "H3 (the commit-time re-pin moves lock resolutions, never a " &
  "recipe constraint)"

proc developSetLine(fx: Nf2Fixture): string =
  ## The most recent `hook-develop-set` line of the pre-commit log.
  for line in preCommitLog(fx).splitLines():
    if " hook-develop-set " in line: result = line

proc afterTimestamp(line: string): string =
  ## The line without its leading timestamp.
  let sp = line.find(' ')
  if sp < 0: line else: line[sp + 1 .. ^1]

proc overridesFile(fx: Nf2Fixture): string =
  fx.ws / ".repro" / "develop-overrides.toml"

proc overridesText(fx: Nf2Fixture): string =
  if fileExists(overridesFile(fx)): readFile(overridesFile(fx)) else: ""

proc overriddenPackages(fx: Nf2Fixture): seq[string] =
  ## The `package` of every `[[override]]` block, in file order.
  for line in overridesText(fx).splitLines():
    let l = line.strip()
    if l.startsWith("package = \""):
      result.add(l["package = \"".len ..< l.len - 1])

proc provenanceOf(fx: Nf2Fixture; package: string): string =
  ## The `provenance` of ``package``'s block, "<none>" when it has none, or ""
  ## when there is no such block.
  var inBlock = false
  for line in overridesText(fx).splitLines():
    let l = line.strip()
    if l == "[[override]]":
      if inBlock: return "<none>"
      continue
    if l == "package = \"" & package & "\"":
      inBlock = true
    elif inBlock and l.startsWith("provenance = \""):
      return l["provenance = \"".len ..< l.len - 1]
  if inBlock: "<none>" else: ""

proc develop(fx: Nf2Fixture; args: string): tuple[code: int; output: string] =
  ## The real `repro develop`, run at the workspace root.
  run(q(fx.repro) & " develop " & args & " --workspace-root=" & q(fx.ws) &
    " --tool-provisioning=path", cwd = fx.ws)

proc developJson(fx: Nf2Fixture; args: string): JsonNode =
  ## The real `repro develop … --json`, stdout only.
  let errPath = fx.scratch / "develop.err"
  let res = run(q(fx.repro) & " develop " & args & " --json" &
    " --workspace-root=" & q(fx.ws) & " --tool-provisioning=path 2>" &
    q(errPath), cwd = fx.ws)
  checkpoint("repro develop " & args & " --json -> " & $res.code & "\n" &
    res.output & "\nstderr:\n" &
    (if fileExists(errPath): readFile(errPath) else: ""))
  try: parseJson(res.output)
  except CatchableError: newJObject()

proc nodeOf(doc: JsonNode; key, name: string): JsonNode =
  ## The element of ``doc[key]`` whose `node` / `name` is ``name``, or an empty
  ## object (never nil: `check` stringifies its operands on failure).
  if doc.kind == JObject and doc.hasKey(key):
    for n in doc[key]:
      if n{"node"}.getStr() == name or n{"name"}.getStr() == name: return n
  newJObject()

proc listRowLine(output, name: string): string =
  ## The `repro develop --list` table row of repo ``name``.
  for line in output.splitLines():
    if line.startsWith(name & " "): return line
  ""

proc listColumn(output, name: string; column: int): string =
  ## Column ``column`` (0-based: name, tier, backend, revision, state, path)
  ## of repo ``name``'s `--list` row, or "" when there is no such row.
  let fields = listRowLine(output, name).splitWhitespace()
  if column < fields.len: fields[column] else: ""

proc bulkSkipSentence(name, where: string): string =
  ## What every bulk-selection surface prints for a skipped exact pin.
  "pinned by recipe at " & where & ": '" & name & "' is not substituted " &
    "by a bulk selection, because an exact recipe pin means that revision, " &
    "not whatever is checked out; `repro develop --only=" & name &
    "` substitutes it"

proc commitAlphaRecipe(fx: Nf2Fixture): string =
  ## Give `alpha` a `repro.nim` whose `versions:` maps 1.0.0 to the tag `a1`,
  ## tag the new commit `a1`, publish, and return it.
  let dir = siblingDir(fx, "alpha")
  writeFile(dir / "repro.nim", "import repro_project_dsl\n\npackage alpha:\n" &
    "  versions:\n    \"1.0.0\":\n      sourceRevision = \"refs/tags/a1\"\n")
  discard gitIn(fx, dir, "add -A")
  discard gitIn(fx, dir, "commit -q -m " & q("alpha recipe"))
  result = headOf(fx, dir)
  discard gitIn(fx, dir, "tag a1")
  discard gitIn(fx, dir, "push -q origin HEAD:main --tags")

suite "HL-11 M5: bulk develop skips exact recipe pins; --drop":

  test "t_bulk_develop_skips_exact_recipe_pins":
    if not nf3Prerequisites("t_bulk_develop_skips_exact_recipe_pins"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # ==== (A) an exact flake.nix pin =====================================
      block flakePin:
        let fx = setupNf2Fixture("bulk-flake", revPinned = ["beta-src"])
        defer: removeDir(fx.scratch)
        isolateNf2Config(fx)
        defer: releaseNf2Config()
        publishAll(fx)
        let betaSeed = fx.seedSha[1]
        let pinLine = lineNumberOf(readFile(fx.app / "flake.nix"),
          "beta-src.url")
        check pinLine > 0
        let where = "app/flake.nix:" & $pinLine

        # ---- --dry-run, --list and their --json forms list it. -----------
        # `app` is excluded throughout: it is the consumer whose commits the
        # hooks gate, and its checkout carries a commit the workspace lock
        # does not name, so `--all` would refuse it as drifted.
        let dry = develop(fx, "--all --except=app --dry-run")
        checkpoint("--all --dry-run -> " & $dry.code & "\n" & dry.output)
        check dry.code == 0
        check ("repro develop --all: skipped beta — " &
          bulkSkipSentence("beta", where)) in dry.output.splitLines()
        let dryDoc = developJson(fx, "--all --except=app --dry-run")
        let dryBeta = nodeOf(dryDoc, "nodes", "beta")
        check dryBeta{"mode"}.getStr() == "pinned-by-recipe"
        check dryBeta{"pinnedByRecipe"}.getStr() == where
        check dryBeta{"ok"}.getBool() == true
        check nodeOf(dryDoc, "nodes", "gamma"){"mode"}.getStr() == "adopted"
        check not nodeOf(dryDoc, "nodes", "gamma").hasKey("pinnedByRecipe")
        let listed = develop(fx, "--list")
        checkpoint("--list -> " & $listed.code & "\n" & listed.output)
        check listed.code == 0
        check listColumn(listed.output, "beta", 4) == "pinned"
        check listColumn(listed.output, "beta", 5) == fx.ws / "beta"
        check listRowLine(listed.output, "beta").endsWith(fx.ws / "beta" &
          "  (pinned by recipe at " & where & ")")
        check ("repro develop --list: " & bulkSkipSentence("beta", where)) in
          listed.output.splitLines()
        let listDoc = developJson(fx, "--list")
        check nodeOf(listDoc, "repos", "beta"){"state"}.getStr() == "pinned"
        check nodeOf(listDoc, "repos", "beta"){"pinnedByRecipe"}.getStr() ==
          where
        check nodeOf(listDoc, "repos", "gamma"){"state"}.getStr() == "at-lock"
        check not fileExists(overridesFile(fx))

        # ---- --all: every other node is recorded, the pinned one is not. -
        let all = develop(fx, "--all --except=app")
        checkpoint("--all -> " & $all.code & "\n" & all.output)
        check all.code == 0
        check ("repro develop --all: skipped beta — " &
          bulkSkipSentence("beta", where)) in all.output.splitLines()
        check overriddenPackages(fx) ==
          @["alpha", "delta", "epsilon", "gamma"]
        check provenanceOf(fx, "gamma") == "repro develop --all"

        # ---- the hooks do not treat the skipped pin as overridden. -------
        let betaNext = moveAndPublishSibling(fx, "beta", "revision 2")
        check betaNext != betaSeed
        let flakeLockBefore = readFile(lockPath(fx))
        let c = tryCommitInApp(fx, "beta is ahead of the release pin")
        checkpoint(c.output)
        checkpoint("pre-commit log:\n" & preCommitLog(fx))
        check c.code == 0
        check H3Head notin c.output
        check readFile(lockPath(fx)) == flakeLockBefore
        check lockedRevOfNode(lockInCommit(fx), "beta-src") == betaSeed
        check afterTimestamp(developSetLine(fx)) ==
          "hook-develop-set consulted: flake.lock:alpha-src=alpha, " &
          "flake.lock:gamma-src=gamma; pinned by recipe, not compared: " &
          "beta-src=beta@" & fx.app / "flake.nix" & ":" & $pinLine &
          " (rev " & betaSeed & ")"
        publishRepo(fx, fx.app)
        let gate = gatePrePush(fx)
        checkpoint("gate output:\n" & gate.output)
        check not hasGateFailure(gate.report, "flake_lock_stale")
        check gate.code == 0

        # ---- positive control: --only substitutes it. --------------------
        # Back at the revision the workspace lock names, so `--only` adopts.
        discard gitIn(fx, siblingDir(fx, "beta"), "checkout -q " & betaSeed)
        let only = develop(fx, "--only=beta")
        checkpoint("--only=beta -> " & $only.code & "\n" & only.output)
        check only.code == 0
        check ("repro develop --all: adopted existing checkout of beta @ " &
          betaSeed & " -> " & fx.ws / "beta") in only.output.splitLines()
        check ("repro develop --all: pinned by recipe at " & where &
          ": 'beta' is selected explicitly (by --only, or by an override an " &
          "explicit selection recorded), so it is substituted") in
          only.output.splitLines()
        check overriddenPackages(fx) ==
          @["alpha", "beta", "delta", "epsilon", "gamma"]
        check provenanceOf(fx, "beta") == "repro develop --only=beta"
        let relisted = develop(fx, "--list")
        check listColumn(relisted.output, "beta", 4) ==
          "develop"
        # The same move now refuses the commit: the experiment is guarded.
        discard gitIn(fx, siblingDir(fx, "beta"), "checkout -q main")
        check headOf(fx, siblingDir(fx, "beta")) == betaNext
        let refused = tryCommitKeepingIndex(fx, "beta substituted explicitly")
        checkpoint(refused.output)
        check refused.code != 0
        check (H3Head & ": the sibling checkout " & siblingDir(fx, "beta") &
          " is at " & betaNext & ", but " & fx.app / "flake.nix" & ":" &
          $pinLine & " pins input 'beta-src' at revision " & betaSeed) in
          refused.output
        check refused.treeAfter == refused.treeBefore

      # ==== (B) an exact repro.nim pin =====================================
      block reproNimPin:
        let fx = setupNf2Fixture("bulk-uses")
        defer: removeDir(fx.scratch)
        isolateNf2Config(fx)
        defer: releaseNf2Config()
        let alphaSeed = fx.seedSha[0]
        let alphaPinned = commitAlphaRecipe(fx)
        check alphaPinned != alphaSeed
        # `app` pins `alpha ==1.0.0` in repro.nim; both of its locks name the
        # revision `versions:` maps 1.0.0 to, so H1 and H2 hold.
        let recipe = "import repro_project_dsl\n\npackage app:\n  uses:\n" &
          "    \"alpha ==1.0.0\"\n"
        writeFile(fx.app / "repro.nim", recipe)
        writeFile(fx.app / "repro.lock", reproLockText(fx, "app",
          headOf(fx, fx.app),
          [lockDepEntry(fx, "alpha", "../alpha", "alpha", alphaPinned)]))
        setFlakePins(fx, alphaPinned, fx.seedSha[1], fx.seedSha[2])
        commitWithoutHook(fx, "app pins alpha ==1.0.0")
        # The workspace lock names the pinned revision too.
        let wsLock = fx.ws / "repro.lock"
        writeFile(wsLock, readFile(wsLock).replace(alphaSeed, alphaPinned))
        publishAll(fx)
        let usesLine = lineNumberOf(recipe, "alpha ==1.0.0")
        check usesLine == 5
        let where = "app/repro.nim:" & $usesLine

        let dry = develop(fx, "--all --except=app --dry-run")
        checkpoint("--all --dry-run -> " & $dry.code & "\n" & dry.output)
        check dry.code == 0
        check ("repro develop --all: skipped alpha — " &
          bulkSkipSentence("alpha", where)) in dry.output.splitLines()
        let listDoc = developJson(fx, "--list")
        check nodeOf(listDoc, "repos", "alpha"){"state"}.getStr() == "pinned"
        check nodeOf(listDoc, "repos", "alpha"){"pinnedByRecipe"}.getStr() ==
          where
        let all = develop(fx, "--all --except=app")
        checkpoint("--all -> " & $all.code & "\n" & all.output)
        check all.code == 0
        check ("repro develop --all: skipped alpha — " &
          bulkSkipSentence("alpha", where)) in all.output.splitLines()
        check overriddenPackages(fx) == @["beta", "delta", "epsilon", "gamma"]

        # ---- the hooks do not treat the skipped pin as overridden. -------
        let alphaNext = moveAndPublishSibling(fx, "alpha", "revision 2")
        let flakeLockBefore = readFile(lockPath(fx))
        let c = tryCommitInApp(fx, "alpha is ahead of the uses pin")
        checkpoint(c.output)
        checkpoint("pre-commit log:\n" & preCommitLog(fx))
        check c.code == 0
        check H3Head notin c.output
        # The entry for alpha is untouched (the re-pin may still add the
        # manifest develop-set siblings it always adds, §14.2).
        check reproLockRevisionOf(readFile(fx.app / "repro.lock"), "alpha") ==
          alphaPinned
        check readFile(lockPath(fx)) == flakeLockBefore
        check reproLockRevisionOf(committedText(fx, "repro.lock"), "alpha") ==
          alphaPinned
        check lockedRevOfNode(lockInCommit(fx), "alpha-src") == alphaPinned
        check alphaNext notin committedText(fx, "repro.lock")
        check ("pinned by recipe, not compared: alpha-src=alpha@" &
          fx.app / "repro.nim" & ":" & $usesLine & " (rev " & alphaPinned &
          ")") in afterTimestamp(developSetLine(fx))

        # ---- positive control: --only substitutes it. --------------------
        discard gitIn(fx, siblingDir(fx, "alpha"), "checkout -q " &
          alphaPinned)
        let only = develop(fx, "--only=alpha")
        checkpoint("--only=alpha -> " & $only.code & "\n" & only.output)
        check only.code == 0
        check ("repro develop --all: adopted existing checkout of alpha @ " &
          alphaPinned & " -> " & fx.ws / "alpha") in only.output.splitLines()
        check provenanceOf(fx, "alpha") == "repro develop --only=alpha"
        discard gitIn(fx, siblingDir(fx, "alpha"), "checkout -q main")
        check headOf(fx, siblingDir(fx, "alpha")) == alphaNext
        let refused = tryCommitKeepingIndex(fx, "alpha substituted explicitly")
        checkpoint(refused.output)
        checkpoint("pre-commit log:\n" & preCommitLog(fx))
        check refused.code != 0
        check (H3Head & ": the sibling checkout " & siblingDir(fx, "alpha") &
          " is at " & alphaNext & ", but " & fx.app / "repro.nim" & ":" &
          $usesLine & " requires 'alpha ==1.0.0'") in refused.output
        check refused.treeAfter == refused.treeBefore

  test "t_flake_override_args_automatic_mode_skips_exact_recipe_pins":
    if not nf3Prerequisites(
        "t_flake_override_args_automatic_mode_skips_exact_recipe_pins"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("args-pin", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let pinLine = lineNumberOf(readFile(fx.app / "flake.nix"),
        "beta-src.url")
      let where = "app/flake.nix:" & $pinLine
      proc overrideInputs(doc: JsonNode): seq[string] =
        if doc.kind == JObject and doc.hasKey("overrides"):
          for o in doc["overrides"]: result.add(o["input"].getStr())
      proc parsed(text: string): JsonNode =
        try: parseJson(text) except CatchableError: newJObject()
      let skipSentence = "NOT substituted: flake input 'beta-src' is pinned " &
        "by recipe at " & where & ", and the automatic mode does not " &
        "substitute an exact recipe pin (it means that revision, not " &
        "whatever is checked out), so it keeps its flake.lock pin. `repro " &
        "develop --only=beta` substitutes it, as does an explicit " &
        "`--only=beta` here or an explicit overrideInputs entry."

      # ---- the automatic mode: the form `useFlakeDevShell` runs. ---------
      let auto = flakeArgs(fx, "--all --json")
      checkpoint("override-args --all --json -> " & $auto.code & "\n" &
        auto.stdout & "\nstderr:\n" & auto.stderr)
      check auto.code == 0
      let doc = parsed(auto.stdout)
      check overrideInputs(doc) == @["alpha-src", "gamma-src"]
      check doc{"pinnedByRecipe"} == %*[{"input": "beta-src", "repo": "beta",
        "pinnedByRecipe": where}]
      check doc{"notices"}.kind == JArray and %skipSentence in
        doc{"notices"}.getElems()
      let text = flakeArgs(fx, "--all")
      checkpoint("override-args --all -> " & $text.code & "\n" & text.stdout &
        "\nstderr:\n" & text.stderr)
      check text.code == 0
      check text.stdout.strip().startsWith("--override-input alpha-src ")
      check "--override-input gamma-src " in text.stdout
      check "beta-src" notin text.stdout
      check ("repro flake override-args: " & skipSentence) in
        text.stderr.splitLines()

      # ---- an explicit input selection substitutes it. -------------------
      let named = flakeArgs(fx, "--only=beta --json")
      checkpoint("override-args --only=beta -> " & $named.code & "\n" &
        named.stdout & "\nstderr:\n" & named.stderr)
      check named.code == 0
      let namedDoc = parsed(named.stdout)
      check overrideInputs(namedDoc) == @["beta-src"]
      check namedDoc{"pinnedByRecipe"} == newJArray()

      # ---- so does an explicit develop override, in the automatic mode. --
      overrideExplicitly(fx, "beta")
      let after = flakeArgs(fx, "--all --json")
      checkpoint("override-args --all (after --only) -> " & $after.code &
        "\n" & after.stdout & "\nstderr:\n" & after.stderr)
      check after.code == 0
      let afterDoc = parsed(after.stdout)
      check overrideInputs(afterDoc) == @["alpha-src", "beta-src", "gamma-src"]
      check afterDoc{"pinnedByRecipe"} == newJArray()

  test "t_a_legacy_bulk_override_does_not_substitute_an_exact_pin":
    if not nf3Prerequisites(
        "t_a_legacy_bulk_override_does_not_substitute_an_exact_pin"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("legacy", revPinned = ["beta-src", "gamma-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      let betaSeed = fx.seedSha[1]
      let gammaSeed = fx.seedSha[2]
      let flakeNix = readFile(fx.app / "flake.nix")
      let betaLine = lineNumberOf(flakeNix, "beta-src.url")
      let gammaLine = lineNumberOf(flakeNix, "gamma-src.url")
      # The two shapes an override on disk can have from before this change:
      # what `repro develop --all` AND `--only` both wrote, and an entry with
      # no provenance (hand-written, or by an older writer). Byte-for-byte the
      # previous serialiser's output.
      createDir(fx.ws / ".repro")
      writeFile(overridesFile(fx),
        "schema = \"reprobuild.workspace.develop-overrides.v1\"\n" &
        "\n[[override]]\n" &
        "package = \"beta\"\n" &
        "local_path = \"" & fx.ws / "beta" & "\"\n" &
        "state = \"editable\"\n" &
        "created_at = \"2026-10-01T00:00:00Z\"\n" &
        "provenance = \"repro develop --all\"\n" &
        "\n[[override]]\n" &
        "package = \"gamma\"\n" &
        "local_path = \"" & fx.ws / "gamma" & "\"\n" &
        "state = \"editable\"\n" &
        "created_at = \"2026-10-01T00:00:00Z\"\n")
      let legacyText = overridesText(fx)
      let betaNext = moveAndPublishSibling(fx, "beta", "revision 2")
      let gammaNext = moveAndPublishSibling(fx, "gamma", "revision 2")
      check betaNext != betaSeed
      check gammaNext != gammaSeed

      # ---- the hooks read both entries as bulk: nothing is compared. -----
      let flakeLockBefore = readFile(lockPath(fx))
      let c = tryCommitInApp(fx, "siblings ahead under legacy overrides")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c.code == 0
      check H3Head notin c.output
      check readFile(lockPath(fx)) == flakeLockBefore
      check afterTimestamp(developSetLine(fx)) ==
        "hook-develop-set consulted: flake.lock:alpha-src=alpha; pinned by " &
        "recipe, not compared: beta-src=beta@" & fx.app / "flake.nix" & ":" &
        $betaLine & " (rev " & betaSeed & "), gamma-src=gamma@" &
        fx.app / "flake.nix" & ":" & $gammaLine & " (rev " & gammaSeed & ")"
      # Reading them changed nothing on disk.
      check overridesText(fx) == legacyText

      # ---- --list shows them pinned and names the ignored entries. -------
      let listed = develop(fx, "--list")
      checkpoint("--list -> " & $listed.code & "\n" & listed.output)
      check listed.code == 0
      check listColumn(listed.output, "beta", 4) == "pinned"
      check listColumn(listed.output, "gamma", 4) ==
        "pinned"
      check ("repro develop --list: the develop override recorded for " &
        "'beta' by a bulk selection (" & overridesFile(fx) & ", provenance " &
        "'repro develop --all') is IGNORED for it: a bulk selection does " &
        "not substitute an exact recipe pin, so the managed hooks do not " &
        "compare it with the checkout, the flake override verbs leave it on " &
        "its pin, and repro build resolves it from the lock rather than the " &
        "checkout. Run " &
        "`repro develop " &
        "--only=beta --workspace-root=" & fx.ws & "` to substitute it " &
        "explicitly, or `repro develop --drop=beta --workspace-root=" &
        fx.ws & "` to remove the entry") in listed.output.splitLines()
      check ("repro develop --list: the develop override recorded for " &
        "'gamma' by a bulk selection (" & overridesFile(fx) & ", provenance " &
        "none) is IGNORED for it") in listed.output

      # ---- re-selecting explicitly records the explicit provenance. ------
      let only = develop(fx, "--only=beta")
      checkpoint("--only=beta -> " & $only.code & "\n" & only.output)
      check only.code == 0
      check ("repro develop --all: beta already in develop mode at " &
        fx.ws / "beta" & " (recorded as an explicit selection (provenance " &
        "'repro develop --only=beta'))") in only.output.splitLines()
      check provenanceOf(fx, "beta") == "repro develop --only=beta"
      check provenanceOf(fx, "gamma") == "<none>"
      check overriddenPackages(fx) == @["beta", "gamma"]

      # ---- the hooks now compare beta, and only beta. --------------------
      let refused = tryCommitKeepingIndex(fx, "beta substituted explicitly")
      checkpoint(refused.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check refused.code != 0
      check (H3Head & ": the sibling checkout " & siblingDir(fx, "beta") &
        " is at " & betaNext & ", but " & fx.app / "flake.nix" & ":" &
        $betaLine & " pins input 'beta-src' at revision " & betaSeed) in
        refused.output
      check "pins input 'gamma-src'" notin refused.output
      check ("repin-constraint refused: rule=H3 system=flake " &
        "dependency=beta-src") in preCommitLog(fx)
      check "dependency=gamma-src" notin preCommitLog(fx)
      check refused.treeAfter == refused.treeBefore

  test "t_the_h3_refusals_drop_command_runs_and_the_commit_succeeds":
    if not nf3Prerequisites(
        "t_the_h3_refusals_drop_command_runs_and_the_commit_succeeds"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("drop", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      overrideExplicitly(fx, "beta")
      overrideExplicitly(fx, "gamma")
      # The same checkout is ALSO substituted through `app`'s per-project
      # override document, under the flake input's name — the shape `repro
      # develop beta-src --into=…` records. The hooks match an override by
      # name or by checkout path, so dropping `beta` must remove this entry
      # too, or the substitution would survive the drop. Written in the
      # document's exact on-disk shape (`writeDevelopOverrides`).
      let appOverrides = fx.app / ".git" / "reprobuild" /
        "develop-overrides.json"
      createDir(parentDir(appOverrides))
      writeFile(appOverrides, pretty(%*{
        "schemaId": "reprobuild.develop-overrides.v1",
        "projectRoot": fx.app,
        "overrides": [{"node": "beta-src", "path": fx.ws / "beta"},
                      {"node": "gamma-src", "path": fx.ws / "gamma"}]}) & "\n")
      publishAll(fx)
      let betaSeed = fx.seedSha[1]
      let pinLine = lineNumberOf(readFile(fx.app / "flake.nix"),
        "beta-src.url")

      # ---- positive control: at the pin, the commit passes. --------------
      let ok = tryCommitInApp(fx, "at the pin")
      checkpoint(ok.output)
      check ok.code == 0
      publishRepo(fx, fx.app)

      # ---- the explicit experiment moves past the pin: refused. ----------
      let betaNext = moveAndPublishSibling(fx, "beta", "revision 2")
      let c = tryCommitKeepingIndex(fx, "experiment past the pin")
      checkpoint(c.output)
      check c.code != 0
      check (H3Head & ": the sibling checkout " & siblingDir(fx, "beta") &
        " is at " & betaNext & ", but " & fx.app / "flake.nix" & ":" &
        $pinLine & " pins input 'beta-src' at revision " & betaSeed) in
        c.output
      check c.treeAfter == c.treeBefore
      let dropCmd = "repro develop --drop=beta --workspace-root=" & fx.ws &
        " --project-root=" & fx.app
      check ("If " & betaNext & " was a temporary experiment, drop the " &
        "develop override of 'beta': `" & dropCmd & "` removes its entry " &
        "from " & overridesFile(fx) & " and " & appOverrides & " and " &
        "leaves the checkout as it is, or check the sibling out at the " &
        "pinned revision: `git -C " & siblingDir(fx, "beta") & " checkout " &
        betaSeed & "`; then commit again") in c.output
      check dropCmd in backtickedCommands(c.output)
      check "no repro command removes a single override" notin c.output

      # ---- the printed command, run verbatim where the commit ran. -------
      let ran = runNamedCommand(fx, dropCmd, fx.app)
      checkpoint("ran `" & dropCmd & "` -> " & $ran.code & "\n" & ran.output)
      check ran.code == 0
      check ran.output.strip().splitLines() == @[
        "repro develop --drop: removed the develop override of 'beta' -> " &
          fx.ws / "beta" & " from " & overridesFile(fx),
        "repro develop --drop: removed the develop override of 'beta' " &
          "(recorded as 'beta-src') -> " & fx.ws / "beta" & " from " &
          appOverrides]
      # Exactly those entries: gamma's overrides (workspace and per-project)
      # are untouched, and the checkout is where the experiment left it.
      check overriddenPackages(fx) == @["gamma"]
      check provenanceOf(fx, "gamma") == "repro develop --only=gamma"
      # Two entries matched `beta`, one by name and one by checkout. The
      # per-project entry of ANOTHER dependency (`gamma-src`, at gamma's
      # checkout) matches neither and is kept.
      check parseJson(readFile(appOverrides))["overrides"] ==
        %*[{"node": "gamma-src", "path": fx.ws / "gamma"}]
      check headOf(fx, siblingDir(fx, "beta")) == betaNext

      # ---- the same commit now succeeds, with flake.lock at the pin. -----
      let again = tryCommitInApp(fx, "experiment past the pin")
      checkpoint(again.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check again.code == 0
      check lockedRevOfNode(lockInCommit(fx), "beta-src") == betaSeed
      check ("pinned by recipe, not compared: beta-src=beta@" &
        fx.app / "flake.nix" & ":" & $pinLine & " (rev " & betaSeed & ")") in
        afterTimestamp(developSetLine(fx))

      # ---- dropping it again is a reported no-op. ------------------------
      let twice = runNamedCommand(fx, dropCmd, fx.app)
      checkpoint(twice.output)
      check twice.code == 0
      check twice.output.strip() == "repro develop --drop: no develop " &
        "override of 'beta' is recorded (looked in: " & overridesFile(fx) &
        ", " & fx.ws / ".repro" / "local" / "develop-overrides.json" & ", " &
        appOverrides & "); nothing to drop"
      check overriddenPackages(fx) == @["gamma"]
      # `--drop` accepts the `--tool-provisioning` flag every other `repro
      # develop` form takes (the helper passes it) instead of refusing it.
      let uniform = develop(fx, "--drop=beta")
      checkpoint(uniform.output)
      check uniform.code == 0
      check uniform.output.strip().endsWith("); nothing to drop")
