## declared_role_does_not_fall_back_when_ref_is_absent
## (Workspace-Branch-Roles.md §9; §2.2 "fallback is on declaration, never on
## ref existence", §4.4 `no_role_ref`).
##
## `core`'s profile declares `unstable = "agents"`, and `core`'s remote has
## no `agents` branch. A role sweep must REFUSE that repo — it must not
## reconcile it with, switch it to, or cut it from the mainline `main`, which
## the remote does have. Falling back when a probe finds no ref would turn a
## deleted or misspelled branch into a silent redirect to another branch.
##
## In the same runs `docs` declares no `unstable` at all, so its `unstable`
## falls back to its mainline by DECLARATION — which must still work. That is
## the control showing the refusal is about the declared-but-absent ref, not
## about `--unstable` failing generally; and `--mainline` on `core` succeeding
## shows `main` really is there to (wrongly) fall back to.
##
## Legs:
##   1. `sync --unstable`: `core` is `no_role_ref` naming `agents` and the
##      declaration, exit 2, HEAD untouched although `main` moved; `docs`
##      fast-forwards to `latest` through `unstable → mainline`.
##   2. `switch --unstable --yes`: `core` is `no_role_ref`, exit 2, and the
##      switch is all-or-nothing, so neither repo moved.
##   3. `branch <path> --unstable`: refused before anything is created, `core`
##      naming `agents` (role `unstable`), no fork directory.
##   4. control: `sync --mainline` fast-forwards `core` to `main`.
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

suite "declared_role_does_not_fall_back_when_ref_is_absent":

  test "declared_role_does_not_fall_back_when_ref_is_absent":
    if findExe("git").len == 0:
      skip("git is not on PATH — the workspace members are real " &
        "repositories behind file:// remotes")
    else:
      let ws = setupRoleWorkspace("noref", withAgents = false)
      defer: removeDirEventually(ws.scratch)
      let rootArg = "--workspace-root=" & ws.root
      let coreHead = ws.gitIn(ws.root / "core", "rev-parse HEAD")
      let docsHead = ws.gitIn(ws.root / "docs", "rev-parse HEAD")

      # ---- 1. sync --unstable -----------------------------------------------
      let sync = ws.runRepro(@["sync", rootArg, "--unstable", "--json"])
      checkpoint("sync --unstable exit=" & $sync.code & "\n" & sync.stdout &
        "\nstderr:\n" & sync.stderr)
      check sync.code == 2
      let doc = parseJson(sync.stdout)
      let core = doc.entry("core")
      check core["outcome"].getStr() == "no_role_ref"
      check core["role"].getStr() == "unstable"
      check core["resolvedRole"].getStr() == "unstable"
      check core["roleBranch"].getStr() == "agents"
      check core["fallbackPath"] == newJArray()
      check "agents" in core["diagnostic"].getStr()
      check "profile 'product'" in core["diagnostic"].getStr()
      check "not redirected" in core["diagnostic"].getStr()
      # Not reconciled with `main`, which moved and which the remote has.
      check ws.gitIn(ws.root / "core", "rev-parse HEAD") == coreHead
      check ws.gitIn(ws.root / "core",
        "rev-parse refs/remotes/origin/main") != coreHead
      # The control: an UNDECLARED `unstable` falls back by declaration.
      let docs = doc.entry("docs")
      check docs["outcome"].getStr() == "fast_forwarded"
      check docs["roleBranch"].getStr() == "latest"
      check docs["fallbackPath"] == %["unstable", "mainline"]
      check ws.gitIn(ws.root / "docs", "rev-parse HEAD") ==
        ws.gitIn(ws.root / "docs", "rev-parse refs/remotes/origin/latest")
      discard ws.gitIn(ws.root / "docs", "reset -q --hard " & docsHead)

      # ---- 2. switch --unstable --yes ----------------------------------------
      let switch = ws.runRepro(@["switch", rootArg, "--unstable", "--yes",
        "--json"])
      checkpoint("switch --unstable exit=" & $switch.code & "\n" &
        switch.stdout & "\nstderr:\n" & switch.stderr)
      check switch.code == 2
      let sdoc = parseJson(switch.stdout)
      check sdoc.entry("core")["outcome"].getStr() == "no_role_ref"
      check sdoc.entry("core")["roleBranch"].getStr() == "agents"
      check sdoc.entry("core")["targetBranch"].getStr() == "agents"
      check "not redirected" in sdoc.entry("core")["diagnostic"].getStr()
      check ws.gitIn(ws.root / "core", "branch --show-current") == "feature/x"
      check ws.gitIn(ws.root / "docs", "branch --show-current") == "feature/x"

      # ---- 3. branch <path> --unstable ---------------------------------------
      let dest = ws.scratch / "fork-unstable"
      let fork = ws.runRepro(@["branch", rootArg, dest, "--unstable",
        "--json"])
      checkpoint("branch --unstable exit=" & $fork.code & "\n" & fork.stdout &
        "\nstderr:\n" & fork.stderr)
      check fork.code == 2
      check not dirExists(dest)
      let fdoc = parseJson(fork.stdout)
      let fcore = fdoc.entry("core")
      check fcore["outcome"].getStr() == "mainline_unresolved"
      check fcore["role"].getStr() == "unstable"
      check fcore["roleBranch"].getStr() == "agents"
      check fcore["resolvedRole"].getStr() == "unstable"
      check "agents" in fcore["diagnostic"].getStr()
      check "not redirected" in fcore["diagnostic"].getStr()
      check fdoc.entry("docs")["outcome"].getStr() == "ready"

      # ---- 4. control: the mainline is there --------------------------------
      let mainline = ws.runRepro(@["sync", rootArg, "--mainline", "--json"])
      checkpoint("sync --mainline exit=" & $mainline.code & "\n" &
        mainline.stdout & "\nstderr:\n" & mainline.stderr)
      check mainline.code == 0
      check parseJson(mainline.stdout).entry("core")["outcome"].getStr() ==
        "fast_forwarded"
      check ws.gitIn(ws.root / "core", "rev-parse HEAD") ==
        ws.gitIn(ws.root / "core", "rev-parse refs/remotes/origin/main")
