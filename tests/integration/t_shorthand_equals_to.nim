## shorthand_equals_to (Workspace-Branch-Roles.md §9; §4.1, §4.2).
##
## Every built-in role's shorthand means exactly `--to=<role>` on `repro sync`
## and `repro switch`, and exactly `--from=<role>` on `repro branch`: the
## report a shorthand produces is BYTE-IDENTICAL to its spelled-out form's,
## text and JSON. The property is what lets a script or an operator use either
## spelling without the output (or anything parsed from it) changing — and it
## fails as soon as one spelling takes a different code path, records its own
## flag text in the report, or resolves a different role.
##
## Legs, each over all six shorthands (`--mainline`, `--unstable`,
## `--staging`, `--stable`, `--production`, `--lts`):
##
##   1. `sync --dry-run`, text and `--json`: the plan, computed without
##      fetching, so both spellings see the same refs.
##   2. `sync` for real, text and `--json`: after each run the members are put
##      back on `feature/x` at their original commit, so both spellings start
##      from the same state, fetch the same refs and fast-forward the same way.
##   3. `switch` without `--yes` (stdin is not a terminal): the refusal report,
##      which carries each repo's resolved target, mutating nothing.
##   4. `switch --yes` for real, text and `--json`, reset in between.
##   5. `branch <path> --from=<role>` against the same destination path (removed
##      in between): the fork report, text and `--json`.
##
## Each leg also checks the run did what the role says (the role branch of
## `core`, a declared role, and of `docs`, which falls back), so two spellings
## that were identically WRONG could not pass.
##
## No mocks: real git repositories behind `file://` remotes and the real
## `repro` binary as a subprocess (see `branch_role_flags_fixture.nim`). Skip
## rule: `git` missing from PATH.

import std/[json, os, strutils, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import branch_role_flags_fixture

const roles = ["mainline", "unstable", "staging", "stable", "production",
               "lts"]

const expectedCore = [("mainline", "main"), ("unstable", "agents"),
                      ("staging", "main"), ("stable", "release"),
                      ("production", "release"), ("lts", "release")]

proc coreBranchFor(role: string): string =
  for (r, b) in expectedCore:
    if r == role:
      return b
  ""

proc entry(doc: JsonNode; name: string): JsonNode =
  result = newJNull()
  for e in doc["repos"]:
    if e["name"].getStr() == name:
      return e

suite "shorthand_equals_to":

  test "shorthand_equals_to":
    if findExe("git").len == 0:
      skip("git is not on PATH — the workspace members are real " &
        "repositories behind file:// remotes")
    else:
      let ws = setupRoleWorkspace("shorthand")
      defer: removeDirEventually(ws.scratch)
      let rootArg = "--workspace-root=" & ws.root

      proc pair(verb: seq[string]; role: string; extra: seq[string];
                spelled = "--to="): tuple[short, long: RoleRun] =
        let short = ws.runRepro(verb & @["--" & role] & extra)
        let long = ws.runRepro(verb & @[spelled & role] & extra)
        checkpoint($verb & " " & role & " " & $extra &
          "\nshorthand exit=" & $short.code & "\n" & short.stdout &
          "\nstderr:\n" & short.stderr &
          "\n--to exit=" & $long.code & "\n" & long.stdout &
          "\nstderr:\n" & long.stderr)
        (short, long)

      # ---- 1. sync --dry-run ------------------------------------------------
      for role in roles:
        for extra in [@["--dry-run"], @["--dry-run", "--json"]]:
          let (short, long) = pair(@["sync", rootArg], role, extra)
          check short.code == 0
          check short.stdout.len > 0
          check short.stdout == long.stdout
        let plan = parseJson(ws.runRepro(@["sync", rootArg, "--" & role,
          "--dry-run", "--json"]).stdout)
        check plan["role"].getStr() == role
        check plan.entry("core")["roleBranch"].getStr() == coreBranchFor(role)
        check plan.entry("docs")["roleBranch"].getStr() == "latest"

      # ---- 2. sync, for real ------------------------------------------------
      for role in roles:
        for extra in [newSeq[string](), @["--json"]]:
          ws.resetFeatureBranches()
          let short = ws.runRepro(@["sync", rootArg, "--" & role] & extra)
          ws.resetFeatureBranches()
          let long = ws.runRepro(@["sync", rootArg, "--to=" & role] & extra)
          checkpoint("sync " & role & " " & $extra & "\nshorthand:\n" &
            short.stdout & short.stderr & "\n--to:\n" & long.stdout &
            long.stderr)
          check short.code == 0
          check short.stdout.len > 0
          check short.stdout == long.stdout
        # The last run (`--to=<role> --json`) really reconciled core with the
        # role's branch.
        let coreTip = ws.gitIn(ws.root / "core",
          "rev-parse refs/remotes/origin/" & coreBranchFor(role))
        check ws.gitIn(ws.root / "core", "rev-parse HEAD") == coreTip
        check ws.gitIn(ws.root / "core", "branch --show-current") ==
          "feature/x"

      # ---- 3. switch, refused for want of --yes -----------------------------
      for role in roles:
        ws.resetFeatureBranches()
        for extra in [newSeq[string](), @["--json"]]:
          let (short, long) = pair(@["switch", rootArg], role, extra)
          check short.code == 2
          check short.stdout.len > 0
          check short.stdout == long.stdout
        let refused = parseJson(ws.runRepro(@["switch", rootArg,
          "--" & role, "--json"]).stdout)
        check refused["role"].getStr() == role
        check refused.entry("core")["targetBranch"].getStr() ==
          coreBranchFor(role)
        check refused.entry("core")["outcome"].getStr() == "confirm_refused"
        # Refusing mutated nothing.
        check ws.gitIn(ws.root / "core", "branch --show-current") ==
          "feature/x"

      # ---- 4. switch --yes, for real -----------------------------------------
      for role in roles:
        for extra in [newSeq[string](), @["--json"]]:
          ws.resetFeatureBranches()
          let short = ws.runRepro(@["switch", rootArg, "--yes",
            "--" & role] & extra)
          ws.resetFeatureBranches()
          let long = ws.runRepro(@["switch", rootArg, "--yes",
            "--to=" & role] & extra)
          checkpoint("switch --yes " & role & " " & $extra & "\nshorthand:\n" &
            short.stdout & short.stderr & "\n--to:\n" & long.stdout &
            long.stderr)
          check short.code == 0
          check short.stdout.len > 0
          check short.stdout == long.stdout
        check ws.gitIn(ws.root / "core", "branch --show-current") ==
          coreBranchFor(role)
        check ws.gitIn(ws.root / "docs", "branch --show-current") == "latest"
      ws.resetFeatureBranches()

      # ---- 5. branch --from=<role> -------------------------------------------
      for role in roles:
        let dest = ws.scratch / ("fork-" & role)
        for extra in [newSeq[string](), @["--json"]]:
          let argv = @["branch", rootArg, dest, "--branch=cut-" & role] & extra
          let short = ws.runRepro(argv & @["--" & role])
          removeDirEventually(dest)
          let long = ws.runRepro(argv & @["--from=" & role])
          checkpoint("branch " & role & " " & $extra & "\nshorthand:\n" &
            short.stdout & short.stderr & "\n--from:\n" & long.stdout &
            long.stderr)
          check short.code == 0
          check short.stdout.len > 0
          check short.stdout == long.stdout
          if extra.len > 0:
            let doc = parseJson(long.stdout)
            check doc["role"].getStr() == role
            check doc.entry("core")["roleBranch"].getStr() ==
              coreBranchFor(role)
            # The fork's core sits at the role branch's tip, not at the
            # source checkout's HEAD.
            check ws.gitIn(dest / "core", "rev-parse HEAD") ==
              ws.gitIn(ws.root / "core",
                "rev-parse refs/remotes/origin/" & coreBranchFor(role))
          removeDirEventually(dest)
