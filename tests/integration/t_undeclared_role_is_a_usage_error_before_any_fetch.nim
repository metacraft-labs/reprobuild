## An undeclared role is a usage error before anything is fetched
## (Workspace-Branch-Roles.md §4.4: "An undeclared custom role name passed to
## `--to` or `--from` is a usage error (exit 2) before anything is fetched";
## §4.1: `--to` and the shorthands are mutually exclusive, and `--rebase` /
## `--merge` require a role).
##
## The members are fresh clones that have never fetched, so a `FETCH_HEAD` in
## either is proof that a refused command reached the network.
##
## Legs, on `sync`, `switch` and `branch`:
##   1. `--to=beta` / `--from=beta` (no `[branch-roles.beta]`): exit 2, nothing
##      on stdout, the message names `beta`, the workspace's roles and the
##      settings file; no fetch, no fork directory.
##   2. two different roles (`--unstable --stable`, `--to=stable --mainline`):
##      exit 2, "mutually exclusive"; the SAME role twice is accepted.
##   3. `sync --rebase` with no role: refused, naming `--to=<role>`.
##   4. the declared custom role `partner` IS accepted by `--to=`.
##   5. `--to=` and `--from=` are not interchangeable: `sync --from=unstable`
##      and `branch <path> --to=unstable` are unknown flags.
##
## No mocks: real git repositories behind `file://` remotes and the real
## `repro` binary (see `branch_role_flags_fixture.nim`). Skip rule: `git`
## missing from PATH.

import std/[json, os, strutils, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import branch_role_flags_fixture

suite "undeclared_role_is_a_usage_error_before_any_fetch":

  test "undeclared_role_is_a_usage_error_before_any_fetch":
    if findExe("git").len == 0:
      skip("git is not on PATH — the workspace members are real " &
        "repositories behind file:// remotes")
    else:
      let ws = setupRoleWorkspace("usage")
      defer: removeDirEventually(ws.scratch)
      let rootArg = "--workspace-root=" & ws.root
      let dest = ws.scratch / "never-created"

      proc run(argv: seq[string]): RoleRun =
        result = ws.runRepro(argv)
        checkpoint($argv & " exit=" & $result.code & "\nstdout:\n" &
          result.stdout & "\nstderr:\n" & result.stderr)

      proc noFetch() =
        check not ws.fetchHeadPresent("core")
        check not ws.fetchHeadPresent("docs")
        check not dirExists(dest)

      # ---- 1. an undeclared role --------------------------------------------
      for argv in [@["sync", rootArg, "--to=beta"],
                   @["switch", rootArg, "--to=beta", "--yes"],
                   @["branch", rootArg, dest, "--from=beta"]]:
        let res = run(argv)
        check res.code == 2
        check res.stdout.len == 0
        check "'beta'" in res.stderr
        check "mainline, unstable, staging, stable, production, lts, " &
          "partner" in res.stderr
        check "repro-workspace.toml" in res.stderr
        noFetch()

      # ---- 2. two different roles ---------------------------------------------
      for argv in [@["sync", rootArg, "--unstable", "--stable"],
                   @["switch", rootArg, "--to=stable", "--mainline", "--yes"],
                   @["branch", rootArg, dest, "--from=stable", "--lts"]]:
        let res = run(argv)
        check res.code == 2
        check res.stdout.len == 0
        check "mutually exclusive" in res.stderr
        noFetch()
      let same = run(@["sync", rootArg, "--to=unstable", "--unstable",
        "--dry-run", "--json"])
      check same.code == 0
      check parseJson(same.stdout)["role"].getStr() == "unstable"

      # ---- 3. --rebase needs a role ------------------------------------------
      let rebase = run(@["sync", rootArg, "--rebase"])
      check rebase.code != 0
      check "--to=<role>" in rebase.stderr
      noFetch()

      # ---- 4. a declared custom role ------------------------------------------
      let partner = run(@["sync", rootArg, "--to=partner", "--dry-run",
        "--json"])
      check partner.code == 0
      check parseJson(partner.stdout)["role"].getStr() == "partner"
      noFetch()

      # ---- 5. direction is part of the flag -------------------------------------
      let syncFrom = run(@["sync", rootArg, "--from=unstable"])
      check syncFrom.code != 0
      check "--from=unstable" in syncFrom.stderr
      let branchTo = run(@["branch", rootArg, dest, "--to=unstable"])
      check branchTo.code != 0
      check "--to=unstable" in branchTo.stderr
      noFetch()
