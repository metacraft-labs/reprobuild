## Unified-Locking-And-Hooks HL-1 (§4.4) — the conflict-precedence rule:
## a CROSS-TIER move between layers is a LOUD error naming BOTH sources.
##
## Disjoint composition (§4.4): layers naming different repos union; a
## higher-precedence layer MAY refine the BACKEND within the SAME tier
## (most-specific wins); but any attempt to move a repo ACROSS a visibility
## tier between layers is a hard ``StoreRoutingError`` that NAMES BOTH declaring
## layers + their sources. Silently letting the higher-precedence layer win
## would break the tier-isolation invariant (§3): a team repo silently turned
## personal drops out of the team backend teammates read; a personal repo
## silently turned team leaks a private revision into a shared backend.
##
## We compose two NAMED routes for the SAME repo at DIFFERENT tiers (team in a
## lower-precedence layer, personal in a higher-precedence layer) and assert:
##   1. Resolution RAISES ``StoreRoutingError`` (never silently resolves).
##   2. The message names the repo AND BOTH tiers (team + personal).
##   3. The message names BOTH declaring layers/sources (parent-workspace repo
##      + VCS-private).
## We also assert the ALLOWED same-tier backend-refinement path does NOT raise:
##   4. Two layers naming the same repo at the SAME tier with different backends
##      resolve to the most-specific (highest-precedence) backend, no error.
##
## Falsifiable: if resolution silently let the higher-precedence layer win the
## tier (instead of erroring), assertion (1) never sees an exception and the
## ``check raised`` trips. Confirmed by replacing the cross-tier ``raise`` with
## a ``continue`` that keeps ``claims[^1]``'s tier: (1) then resolves quietly and
## the test fails.
##
## Hermetic: temp workspace; no ``$HOME`` / shared-cache access. Skip: no git.

import std/[options, os, strutils, tempfiles, unittest]

import repro_cli_support
import repro_workspace_manifests
import git_tool

suite "HL-1 — cross-tier move between layers errors loudly":

  test "t_cross_tier_move_between_layers_errors_loudly":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let ws = createTempDir("repro-hl1-crosstier-", "")
      defer: removeDir(ws)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      let repos = @[ResolvedRepo(name: "core", path: "core",
        visibility: wvPublic)]

      let teamSource = ws / ".repro-workspace.toml"
      let personalSource = ws / ".git" / "repro" / "config.toml"

      # ---- (1)-(3) a cross-tier move: team (layer 4) → personal (layer 5) --
      # Routes are appended in INCREASING precedence order; personal is the
      # higher-precedence (later) claim. This is a genuine re-tiering.
      let composedConflict = ComposedRouting(routes: @[
        ComposedRoute(
          tier: wvTeam,
          entry: LockingRouteEntry(visibility: "team",
            backend: "git-checkout", path: some("manifests-team"),
            repos: @["core"]),
          layer: clkParentWorkspace, source: teamSource, repos: @["core"]),
        ComposedRoute(
          tier: wvPersonal,
          entry: LockingRouteEntry(visibility: "personal",
            backend: "external-cli", program: some("personal-store.sh"),
            repos: @["core"]),
          layer: clkVcsPrivate, source: personalSource, repos: @["core"])])

      var raised = false
      try:
        discard resolveRepoBackends(
          composedConflict, repos, ws, identity, gitBin)
      except StoreRoutingError as err:
        raised = true
        # Names the repo.
        check err.msg.contains("core")
        # Names BOTH tiers.
        check err.msg.contains("team")
        check err.msg.contains("personal")
        # Names BOTH declaring layers.
        check err.msg.contains("parent-workspace-repo")
        check err.msg.contains("vcs-private")
        # Names BOTH sources.
        check err.msg.contains(teamSource)
        check err.msg.contains(personalSource)
      check raised

      # ---- (4) same-tier backend refinement is ALLOWED (no error) --------
      # Two layers name ``core`` at the SAME (team) tier; the higher-precedence
      # layer refines the backend location. Most-specific wins, no raise.
      let composedRefine = ComposedRouting(routes: @[
        ComposedRoute(
          tier: wvTeam,
          entry: LockingRouteEntry(visibility: "team",
            backend: "git-checkout", path: some("manifests-broad"),
            repos: @["core"]),
          layer: clkSystem, source: "/etc/reprobuild/config.toml",
          repos: @["core"]),
        ComposedRoute(
          tier: wvTeam,
          entry: LockingRouteEntry(visibility: "team",
            backend: "git-checkout", path: some("manifests-specific"),
            repos: @["core"]),
          layer: clkParentWorkspace, source: teamSource, repos: @["core"])])

      var refineRaised = false
      var asg: seq[RepoBackendAssignment]
      try:
        asg = resolveRepoBackends(composedRefine, repos, ws, identity, gitBin)
      except StoreRoutingError:
        refineRaised = true
      check not refineRaised
      check asg.len == 1
      # Same tier throughout; the most-specific (parent-workspace) layer won.
      check asg[0].visibility == wvTeam
      check asg[0].declaringLayer == clkParentWorkspace
