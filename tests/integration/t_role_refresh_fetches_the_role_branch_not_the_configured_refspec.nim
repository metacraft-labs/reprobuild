## role_refresh_fetches_the_role_branch_not_the_configured_refspec
## (CLI/branch.md §"Fetching", CLI/sync.md, CLI/switch.md §"Fetching";
## Workspace-Branch-Roles.md §2.2).
##
## A role refresh fetches the ROLE BRANCH, by an explicit refspec, whatever
## the checkout's own fetch configuration or current branch's upstream names.
##
## The conditions recreated are the ones observed on a real workspace: a
## checkout made by ``git clone --single-branch`` (so ``remote.origin.fetch``
## names ONE branch) on a branch the remote has since renamed away. A bare
## ``git fetch origin`` in that checkout fails with
## ``fatal: couldn't find remote ref refs/heads/<old>`` even though the role
## branch is on the remote, and every role refresh that delegated to it
## refused the whole run as ``mainline_fetch_failed`` / a fetch failure.
##
## Here ``core``'s checkout is narrowed to ``refs/heads/old-main`` and sits on
## a local ``old-main`` tracking it; then ``old-main`` is deleted on the
## remote. The workspace root gets the same treatment, so the root's own
## role refresh under ``repro branch`` is covered too. ``main`` (core's
## mainline) and the root's ``main`` both exist and have moved on.
##
## Legs:
##   0. Proof the conditions hold: ``git fetch origin`` fails in both
##      checkouts with "couldn't find remote ref refs/heads/old-main".
##   1. ``branch <path> --mainline``: exit 0, ``core`` cut from the CURRENT
##      ``main`` tip (so the refresh really reached the remote), the root cut
##      from its current ``main``; the source checkout is not moved.
##   2. ``sync --mainline``: ``core`` fast-forwards to the current ``main``.
##   3. ``switch --mainline --yes`` with a local ``main``: ``core`` lands on
##      ``main`` at its current tip (the switch prefetch refreshed it).
##   4. ``switch --mainline --yes`` with NO local ``main`` (the observed state:
##      only the renamed-away branch exists locally): the fetch-and-track step
##      creates ``main`` from ``origin/main`` and records its upstream. git's
##      own remote-branch guess goes through the narrow refspec and would
##      refuse with "invalid reference".
##
## Separate cases:
##   - an ABSENT role branch is still ``no_role_ref``, not a fetch failure
##     (§2.2), and a remote-tracking ref left by an earlier fetch of a branch
##     the remote has since deleted is removed rather than reconciled with;
##   - an UNREACHABLE remote is still a failure (``sync``: ``fetch_failed``;
##     ``branch``: refused in pre-flight by whichever network step meets it
##     first), never read as an absent branch.
##
## No mocks: real git repositories behind ``file://`` remotes and the real
## ``repro`` binary (see ``branch_role_flags_fixture.nim``). Skip rule: ``git``
## missing from PATH.

import std/[json, os, osproc, strutils, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import branch_role_flags_fixture

proc entry(doc: JsonNode; name: string): JsonNode =
  result = newJNull()
  for e in doc["repos"]:
    if e["name"].getStr() == name or e["path"].getStr() == name:
      return e

proc narrowToGoneBranch(ws: RoleWorkspace; checkout, bareRemote: string) =
  ## Make ``checkout`` look like a ``clone --single-branch`` of a branch
  ## ``old-main`` that the remote then renamed away: publish ``old-main`` at
  ## the checkout's HEAD, narrow ``remote.origin.fetch`` to it, put the
  ## checkout on a local ``old-main`` tracking it, then delete it remotely.
  discard ws.gitIn(checkout, "push -q origin HEAD:refs/heads/old-main")
  discard ws.gitIn(checkout, "config --replace-all remote.origin.fetch " &
    q("+refs/heads/old-main:refs/remotes/origin/old-main"))
  discard ws.gitIn(checkout, "fetch -q origin")
  discard ws.gitIn(checkout, "switch -q -c old-main --track origin/old-main")
  discard ws.gitIn(bareRemote, "branch -q -D old-main")

proc moveOn(ws: RoleWorkspace; name, branch, tag: string): string =
  ## Land one more commit on ``branch`` of remote ``name`` and return the new
  ## tip. The fixture's ``advanceRemote`` writes the same file every time, so
  ## a second call for one branch has nothing to commit; ``tag`` keeps each
  ## commit distinct.
  let work = ws.scratch / ("seed-" & name)
  discard ws.gitIn(work, "switch -q " & branch)
  writeFile(work / ("moved-" & tag), tag & "\n")
  discard ws.gitIn(work, "add -A")
  discard ws.gitIn(work, "commit -q -m " & q(branch & " moves on: " & tag))
  discard ws.gitIn(work, "push -q " & q(ws.remotes / name) & " " & branch)
  ws.gitIn(work, "rev-parse HEAD")

proc bareFetchFails(ws: RoleWorkspace; checkout: string): string =
  ## The output of a bare ``git fetch origin``, which must fail.
  let res = execCmdEx(q(ws.gitBin) & " -C " & q(checkout) & " fetch origin")
  check res.exitCode != 0
  res.output

suite "role_refresh_fetches_the_role_branch_not_the_configured_refspec":

  test "role_refresh_fetches_the_role_branch_not_the_configured_refspec":
    if findExe("git").len == 0:
      skip("git is not on PATH — the workspace members are real " &
        "repositories behind file:// remotes")
    else:
      let ws = setupRoleWorkspace("narrow-refspec")
      defer: removeDirEventually(ws.scratch)
      let rootArg = "--workspace-root=" & ws.root
      let core = ws.root / "core"

      # The root carries no local edits of its own; commit nothing. Its
      # `old-main` is published from its current HEAD (`main`).
      narrowToGoneBranch(ws, core, ws.remotes / "core")
      narrowToGoneBranch(ws, ws.root, ws.rootOrigin)

      # Both mainlines move on AFTER the narrowing, so a run that cut from the
      # stale remote-tracking refs would land on the wrong commit.
      let coreMain = ws.moveOn("core", "main", "before-branch")
      let rootSeed = ws.scratch / "seed-root"
      writeFile(rootSeed / "MOVED", "root main moves on\n")
      discard ws.gitIn(rootSeed, "add -A")
      discard ws.gitIn(rootSeed, "commit -q -m " & q("root main moves on"))
      discard ws.gitIn(rootSeed, "push -q " & q(ws.rootOrigin) & " main")
      let rootMain = ws.gitIn(rootSeed, "rev-parse HEAD")
      let coreSourceHead = ws.gitIn(core, "rev-parse HEAD")
      check coreSourceHead != coreMain
      check ws.gitIn(core, "rev-parse refs/remotes/origin/main") != coreMain

      # ---- 0. the conditions hold -------------------------------------------
      for checkout in [core, ws.root]:
        let output = bareFetchFails(ws, checkout)
        checkpoint("git fetch origin in " & checkout & ":\n" & output)
        check "couldn't find remote ref refs/heads/old-main" in output

      # ---- 1. branch <path> --mainline --------------------------------------
      let dest = ws.scratch / "fork-mainline"
      let fork = ws.runRepro(@["branch", rootArg, dest, "--mainline",
        "--branch=feature/narrow", "--json"])
      checkpoint("branch --mainline exit=" & $fork.code & "\n" & fork.stdout &
        "\nstderr:\n" & fork.stderr)
      check fork.code == 0
      check "mainline_fetch_failed" notin fork.stdout
      check "couldn't find remote ref" notin fork.stdout & fork.stderr
      check dirExists(dest / "core" / ".git")
      if dirExists(dest / "core" / ".git"):
        check ws.gitIn(dest / "core", "rev-parse HEAD") == coreMain
      check dirExists(dest / ".git")
      if dirExists(dest / ".git"):
        check ws.gitIn(dest, "rev-parse HEAD") == rootMain
      # The source checkouts were refreshed, not moved.
      check ws.gitIn(core, "branch --show-current") == "old-main"
      check ws.gitIn(core, "rev-parse HEAD") == coreSourceHead
      check ws.gitIn(ws.root, "branch --show-current") == "old-main"

      # ---- 2. sync --mainline -----------------------------------------------
      let coreMain2 = ws.moveOn("core", "main", "before-sync")
      let sync = ws.runRepro(@["sync", rootArg, "--mainline", "--json"])
      checkpoint("sync --mainline exit=" & $sync.code & "\n" & sync.stdout &
        "\nstderr:\n" & sync.stderr)
      check sync.code == 0
      let sdoc = parseJson(sync.stdout)
      check sdoc.entry("core")["outcome"].getStr() == "fast_forwarded"
      check ws.gitIn(core, "rev-parse HEAD") == coreMain2
      discard ws.gitIn(core, "reset -q --hard " & coreSourceHead)

      # ---- 3. switch --mainline --yes ---------------------------------------
      let coreMain3 = ws.moveOn("core", "main", "before-switch")
      let switch = ws.runRepro(@["switch", rootArg, "--mainline", "--yes",
        "--json"])
      checkpoint("switch --mainline exit=" & $switch.code & "\n" &
        switch.stdout & "\nstderr:\n" & switch.stderr)
      check switch.code == 0
      check ws.gitIn(core, "branch --show-current") == "main"
      check ws.gitIn(core, "rev-parse HEAD") == coreMain3

      # ---- 4. switch --mainline --yes, no local main (fetch-and-track) ----
      discard ws.gitIn(core, "switch -q old-main")
      discard ws.gitIn(core, "branch -q -D main")
      let coreMain4 = ws.moveOn("core", "main", "before-track")
      # The precondition, proven on a throwaway copy so the checkout itself
      # is untouched: with `origin/main` present, git's own guess still
      # refuses, because the narrow refspec maps no `main`.
      discard ws.gitIn(core, "fetch -q origin " &
        q("+refs/heads/main:refs/remotes/origin/main"))
      let probe = ws.scratch / "guess-probe"
      copyDir(core, probe)
      let guess = execCmdEx(q(ws.gitBin) & " -C " & q(probe) &
        " switch main")
      checkpoint("git switch main in the probe copy:\n" & guess.output)
      check guess.exitCode != 0
      check "invalid reference" in guess.output
      removeDir(probe)
      let track = ws.runRepro(@["switch", rootArg, "--mainline", "--yes",
        "--json"])
      checkpoint("switch --mainline (track) exit=" & $track.code & "\n" &
        track.stdout & "\nstderr:\n" & track.stderr)
      check track.code == 0
      check "invalid reference" notin track.stdout & track.stderr
      check ws.gitIn(core, "branch --show-current") == "main"
      check ws.gitIn(core, "rev-parse HEAD") == coreMain4
      check ws.gitIn(core, "config branch.main.remote") == "origin"
      check ws.gitIn(core, "config branch.main.merge") == "refs/heads/main"

  test "an_absent_role_branch_is_still_no_role_ref_not_a_fetch_failure":
    if findExe("git").len == 0:
      skip("git is not on PATH — the workspace members are real " &
        "repositories behind file:// remotes")
    else:
      # ---- 4. control -------------------------------------------------------
      let ws = setupRoleWorkspace("narrow-noref", withAgents = false)
      defer: removeDirEventually(ws.scratch)
      let rootArg = "--workspace-root=" & ws.root
      let coreCheckout = ws.root / "core"
      narrowToGoneBranch(ws, coreCheckout, ws.remotes / "core")
      # An `agents` existed once, ahead of `core`'s HEAD, and this checkout
      # fetched it; then the remote deleted it. Its stale remote-tracking ref
      # must not stand in for the branch.
      let coreRemote = ws.remotes / "core"
      discard ws.gitIn(coreRemote, "branch -q agents main")
      discard ws.gitIn(coreCheckout, "fetch -q origin " &
        q("+refs/heads/agents:refs/remotes/origin/agents"))
      let staleAgents = ws.gitIn(coreCheckout,
        "rev-parse refs/remotes/origin/agents")
      check staleAgents != ws.gitIn(coreCheckout, "rev-parse HEAD")
      discard ws.gitIn(coreRemote, "branch -q -D agents")
      let headBefore = ws.gitIn(coreCheckout, "rev-parse HEAD")
      let sync = ws.runRepro(@["sync", rootArg, "--unstable", "--json"])
      checkpoint("sync --unstable exit=" & $sync.code & "\n" & sync.stdout &
        "\nstderr:\n" & sync.stderr)
      check sync.code == 2
      let core = parseJson(sync.stdout).entry("core")
      check core["outcome"].getStr() == "no_role_ref"
      check core["roleBranch"].getStr() == "agents"
      check "not redirected" in core["diagnostic"].getStr()
      check "couldn't find remote ref" notin sync.stdout & sync.stderr
      check ws.gitIn(coreCheckout, "rev-parse HEAD") == headBefore
      check execCmdEx(q(ws.gitBin) & " -C " & q(coreCheckout) &
        " rev-parse --verify -q refs/remotes/origin/agents").exitCode != 0

  test "an_unreachable_remote_is_still_a_fetch_failure":
    if findExe("git").len == 0:
      skip("git is not on PATH — the workspace members are real " &
        "repositories behind file:// remotes")
    else:
      let ws = setupRoleWorkspace("narrow-unreachable")
      defer: removeDirEventually(ws.scratch)
      let rootArg = "--workspace-root=" & ws.root
      narrowToGoneBranch(ws, ws.root / "core", ws.remotes / "core")
      # The remote disappears: `ls-remote` cannot answer, so the explicit
      # refspec's failure must NOT be read as "the branch is absent".
      moveDir(ws.remotes / "core", ws.remotes / "core.away")
      defer: moveDir(ws.remotes / "core.away", ws.remotes / "core")
      let sync = ws.runRepro(@["sync", rootArg, "--mainline", "--json"])
      checkpoint("sync --mainline exit=" & $sync.code & "\n" & sync.stdout &
        "\nstderr:\n" & sync.stderr)
      check sync.code != 0
      let core = parseJson(sync.stdout).entry("core")
      check core["outcome"].getStr() == "fetch_failed"
      let dest = ws.scratch / "fork-unreachable"
      let fork = ws.runRepro(@["branch", rootArg, dest, "--mainline",
        "--json"])
      checkpoint("branch --mainline exit=" & $fork.code & "\n" &
        fork.stdout & "\nstderr:\n" & fork.stderr)
      # Refused, nothing created, and never read as an ABSENT mainline. The
      # tag is whichever pre-flight network step meets the dead remote first:
      # the branch-collision probe (`probe_failed`) runs in the same phase as
      # the mainline fetch (CLI/branch.md §"Fetching"), and either is a
      # failure to reach the remote, which is the property at stake here.
      check fork.code != 0
      check not dirExists(dest)
      let forkCore = parseJson(fork.stdout).entry("core")["outcome"].getStr()
      check forkCore in ["probe_failed", "mainline_fetch_failed"]
      check forkCore != "mainline_unresolved"
