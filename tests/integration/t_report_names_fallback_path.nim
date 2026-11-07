## report_names_fallback_path (Workspace-Branch-Roles.md §9; §4.4).
##
## Every per-repo entry of the `sync`, `switch` and `branch` reports names the
## role requested (`role`), the role whose declaration supplied the branch
## (`resolvedRole`), the branch (`roleBranch`) and the chain followed
## (`fallbackPath`, EMPTY when the role was declared directly); and the text
## form shows the chain with arrows only when there was a fallback:
##
##   core  feature/x <- agents (unstable)
##   docs  feature/x <- latest (unstable → mainline)
##
## A `--stable` sweep that lands a repo on its mainline because nobody declared
## its `stable` is a quiet downgrade from released code to unreleased code
## unless the report says so; this test is what keeps it saying so.
##
## Legs:
##   1. `sync --unstable --json`: `core` declared directly (empty path),
##      `docs` through `unstable → mainline`; the tally names the role.
##   2. `sync --unstable --verbose` text: §4.4's arrow form for both repos.
##   3. `sync --production --dry-run --json`: a two-step chain
##      (`production → stable`) and a three-step one
##      (`production → stable → mainline`).
##   4. `switch --unstable --yes`: the JSON fields and the text annotation.
##   5. `branch <path> --production`: the JSON fields for both members and
##      the root repo, and the text form `production=release (production →
##      stable)`.
##   6. `sync --to=partner --dry-run --json`: a custom role's chain through
##      its declared `fallback`.
##
## No mocks: real git repositories behind `file://` remotes and the real
## `repro` binary (see `branch_role_flags_fixture.nim`). Skip rule: `git`
## missing from PATH.

import std/[json, os, strutils, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import branch_role_flags_fixture

proc entry(doc: JsonNode; name: string): JsonNode =
  result = newJNull()
  for e in doc["repos"]:
    if e["name"].getStr() == name:
      return e

proc checkRole(e: JsonNode; role, resolvedRole, branch: string;
               path: openArray[string]) =
  checkpoint("entry: " & $e)
  check e["role"].getStr() == role
  check e["resolvedRole"].getStr() == resolvedRole
  check e["roleBranch"].getStr() == branch
  check e["fallbackPath"] == %(@path)

suite "report_names_fallback_path":

  test "report_names_fallback_path":
    if findExe("git").len == 0:
      skip("git is not on PATH — the workspace members are real " &
        "repositories behind file:// remotes")
    else:
      let ws = setupRoleWorkspace("fallback-path")
      defer: removeDirEventually(ws.scratch)
      let rootArg = "--workspace-root=" & ws.root

      # ---- 1. sync --unstable, JSON ----------------------------------------
      let sync = ws.runRepro(@["sync", rootArg, "--unstable", "--json"])
      checkpoint("sync --unstable --json exit=" & $sync.code & "\n" &
        sync.stdout & "\nstderr:\n" & sync.stderr)
      check sync.code == 0
      let doc = parseJson(sync.stdout)
      check doc["role"].getStr() == "unstable"
      doc.entry("core").checkRole("unstable", "unstable", "agents", [])
      doc.entry("docs").checkRole("unstable", "mainline", "latest",
        ["unstable", "mainline"])

      # ---- 2. sync --unstable, text -----------------------------------------
      ws.resetFeatureBranches()
      let text = ws.runRepro(@["sync", rootArg, "--unstable", "--verbose"])
      checkpoint("sync --unstable --verbose exit=" & $text.code & "\n" &
        text.stdout & "\nstderr:\n" & text.stderr)
      check text.code == 0
      check "workspace sync: core fast_forwarded feature/x <- agents " &
        "(unstable)\n" in text.stdout
      check "workspace sync: docs fast_forwarded feature/x <- latest " &
        "(unstable → mainline)\n" in text.stdout
      check "workspace sync --to=unstable: 2 fast_forwarded (2 repo(s))" in
        text.stdout

      # ---- 3. two- and three-step chains --------------------------------------
      ws.resetFeatureBranches()
      let prod = ws.runRepro(@["sync", rootArg, "--production", "--dry-run",
        "--json"])
      checkpoint("sync --production exit=" & $prod.code & "\n" & prod.stdout &
        "\nstderr:\n" & prod.stderr)
      check prod.code == 0
      let pdoc = parseJson(prod.stdout)
      pdoc.entry("core").checkRole("production", "stable", "release",
        ["production", "stable"])
      pdoc.entry("docs").checkRole("production", "mainline", "latest",
        ["production", "stable", "mainline"])
      let prodText = ws.runRepro(@["sync", rootArg, "--production",
        "--dry-run"])
      check "feature/x <- release (production → stable)" in prodText.stdout
      check "feature/x <- latest (production → stable → mainline)" in
        prodText.stdout

      # ---- 4. switch --unstable --------------------------------------------
      ws.resetFeatureBranches()
      let sw = ws.runRepro(@["switch", rootArg, "--unstable", "--yes",
        "--json"])
      checkpoint("switch --unstable exit=" & $sw.code & "\n" & sw.stdout &
        "\nstderr:\n" & sw.stderr)
      check sw.code == 0
      let sdoc = parseJson(sw.stdout)
      check sdoc["role"].getStr() == "unstable"
      sdoc.entry("core").checkRole("unstable", "unstable", "agents", [])
      sdoc.entry("docs").checkRole("unstable", "mainline", "latest",
        ["unstable", "mainline"])
      ws.resetFeatureBranches()
      let swText = ws.runRepro(@["switch", rootArg, "--unstable", "--yes"])
      checkpoint("switch --unstable text:\n" & swText.stdout & swText.stderr)
      check swText.code == 0
      check "workspace switch: core fetched_and_switched feature/x -> " &
        "agents [agents (unstable)]\n" in swText.stdout
      check "workspace switch: docs fetched_and_switched feature/x -> " &
        "latest [latest (unstable → mainline)]\n" in swText.stdout
      check "workspace switch: unstable active across 2 repos " &
        "(agents, latest)" in swText.stdout
      ws.resetFeatureBranches()

      # ---- 5. branch --production ------------------------------------------
      let dest = ws.scratch / "fork-production"
      let fork = ws.runRepro(@["branch", rootArg, dest, "--production",
        "--json"])
      checkpoint("branch --production exit=" & $fork.code & "\n" &
        fork.stdout & "\nstderr:\n" & fork.stderr)
      check fork.code == 0
      let fdoc = parseJson(fork.stdout)
      check fdoc["role"].getStr() == "production"
      fdoc.entry("core").checkRole("production", "stable", "release",
        ["production", "stable"])
      fdoc.entry("docs").checkRole("production", "mainline", "latest",
        ["production", "stable", "mainline"])
      # The root repo declares only `[workspace] mainline = "main"`.
      fdoc.entry("<workspace-root>").checkRole("production", "mainline",
        "main", ["production", "stable", "mainline"])
      removeDirEventually(dest)
      let forkText = ws.runRepro(@["branch", rootArg, dest, "--production"])
      checkpoint("branch --production text:\n" & forkText.stdout &
        forkText.stderr)
      check forkText.code == 0
      check "workspace branch: core branched_from_mainline " &
        "production=release (production → stable) head=" in forkText.stdout
      check "workspace branch: docs branched_from_mainline " &
        "production=latest (production → stable → mainline) head=" in
        forkText.stdout
      removeDirEventually(dest)

      # ---- 6. a custom role ---------------------------------------------------
      let partner = ws.runRepro(@["sync", rootArg, "--to=partner",
        "--dry-run", "--json"])
      checkpoint("sync --to=partner exit=" & $partner.code & "\n" &
        partner.stdout & "\nstderr:\n" & partner.stderr)
      check partner.code == 0
      let cdoc = parseJson(partner.stdout)
      cdoc.entry("core").checkRole("partner", "mainline", "main",
        ["partner", "staging", "mainline"])
