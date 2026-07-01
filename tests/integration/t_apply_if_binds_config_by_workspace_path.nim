## Unified-Locking-And-Hooks HL-1 (§4.2, Q-B) — the ``apply-if`` directive is a
## PATH-SCOPED binding: a config it references applies to a workspace checked
## out UNDER its ``under`` path, and NOT to a workspace outside that scope.
## Modeled on Git's ``includeIf "gitdir:…"``.
##
## This drives the composed configuration plane (``composeLockingRouting`` +
## ``resolveRepoBackends``) with the layer config paths pointed at fixtures via
## the ``REPROBUILD_SYSTEM_CONFIG`` / ``REPROBUILD_USER_CONFIG`` overrides, and
## covers BOTH mechanisms the spec calls "the same at different scopes":
##
##   * a SYSTEM-config ``apply-if`` (layer 2) that binds a TEAM route under an
##     org path — team-WITHOUT-a-workspace-repo, IT-shipped;
##   * a USER-dotfiles ``apply-if`` (layer 3) that binds a PERSONAL route under
##     a personal-projects path.
##
## Assertions:
##   1. A workspace checked out UNDER the org scope resolves its named team repo
##      to the team backend the system-config ``apply-if`` referenced.
##   2. A workspace checked out UNDER the personal scope resolves its named
##      personal repo to the personal backend the dotfiles ``apply-if``
##      referenced.
##   3. A workspace checked out OUTSIDE every scope sees NEITHER route — its
##      would-be private repo is UNROUTED and resolution fails loud
##      (``StoreRoutingError``), proving the binding did not leak out of scope.
##
## Falsifiable: if ``under`` scoping were ignored (every ``apply-if`` always
## applied), assertion (3)'s out-of-scope workspace WOULD get the routes and
## resolve without error — the ``check raised`` trips. Confirmed by making
## ``workspaceUnderApplyIfScope`` return ``true`` unconditionally: (3) then
## resolves quietly and fails.
##
## Hermetic: temp dirs for scopes + fixtures; config paths come from env
## overrides, never ``$HOME`` or ``/etc``. Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_cli_support
import repro_workspace_manifests
import git_tool

proc mkRepo(name, path: string; v: WorkspaceVisibility): ResolvedRepo =
  ResolvedRepo(name: name, path: path, visibility: v)

proc tomlPath(p: string): string =
  ## A TOML basic-string literal for a filesystem path (forward-slash on the
  ## platforms this test runs; quotes escaped defensively).
  '"' & p.replace("\\", "\\\\").replace("\"", "\\\"") & '"'

suite "HL-1 — apply-if binds config by workspace-checkout path":

  test "t_apply_if_binds_config_by_workspace_path":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-hl1-applyif-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # ---- scope roots + workspaces --------------------------------------
      let orgScope = scratch / "org"
      let personalScope = scratch / "home-projects"
      let outsideScope = scratch / "elsewhere"
      let orgWs = orgScope / "acme" / "ws"          # under orgScope
      let personalWs = personalScope / "hobby" / "ws"  # under personalScope
      let outsideWs = outsideScope / "ws"           # under NEITHER
      for d in [orgWs, personalWs, outsideWs]:
        createDir(d)

      # ---- fixture config dirs -------------------------------------------
      let cfgDir = scratch / "config"
      createDir(cfgDir)

      # A team-routes file the SYSTEM apply-if references (absolute config path).
      let teamRoutes = cfgDir / "team-routes.toml"
      writeFile(teamRoutes,
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \"manifests-team\", repos = [\"teamlib\"] }]\n")

      # The SYSTEM config (layer 2): apply-if under the org scope → team routes.
      let systemCfg = cfgDir / "system.toml"
      writeFile(systemCfg,
        "schema = \"reprobuild.config.v1\"\n\n" &
        "apply_if = [{ under = " & tomlPath(orgScope) &
        ", config = " & tomlPath(teamRoutes) & " }]\n")

      # A personal-routes file the USER dotfiles apply-if references.
      let personalRoutes = cfgDir / "personal-routes.toml"
      writeFile(personalRoutes,
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"personal\", backend = \"git-notes\", " &
        "repos = [\"diary\"] }]\n")

      # The USER dotfiles config (layer 3): apply-if under the personal scope.
      let userCfg = cfgDir / "user.toml"
      writeFile(userCfg,
        "schema = \"reprobuild.config.v1\"\n\n" &
        "apply_if = [{ under = " & tomlPath(personalScope) &
        ", config = " & tomlPath(personalRoutes) & " }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", systemCfg)
      putEnv("REPROBUILD_USER_CONFIG", userCfg)
      # Make sure no stray real layer-5 file interferes: point it nowhere.
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "nonexistent.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (1) org-scope workspace gets the SYSTEM-config team route -----
      block orgInScope:
        let composed = composeLockingRouting(orgWs, gitBin)
        check composed.hasExplicitRoutes
        let repos = @[mkRepo("teamlib", "teamlib", wvPublic)]
        let asg = resolveRepoBackends(composed, repos, orgWs, identity, gitBin)
        check asg.len == 1
        check asg[0].visibility == wvTeam
        check asg[0].backendKind == "git-checkout"
        check asg[0].declaringLayer == clkSystem

      # ---- (2) personal-scope workspace gets the DOTFILES personal route -
      block personalInScope:
        let composed = composeLockingRouting(personalWs, gitBin)
        check composed.hasExplicitRoutes
        let repos = @[mkRepo("diary", "diary", wvPublic)]
        let asg = resolveRepoBackends(
          composed, repos, personalWs, identity, gitBin)
        check asg.len == 1
        check asg[0].visibility == wvPersonal
        check asg[0].backendKind == "git-notes"
        check asg[0].declaringLayer == clkUserDotfiles

      # ---- (3) out-of-scope workspace gets NEITHER route -----------------
      block outOfScope:
        let composed = composeLockingRouting(outsideWs, gitBin)
        # No apply-if activated → no explicit routes at all.
        check not composed.hasExplicitRoutes
        # A private repo present here is therefore UNROUTED → loud failure,
        # proving the in-scope bindings did not leak out.
        let repos = @[mkRepo("teamlib", "teamlib", wvTeam)]
        var raised = false
        try:
          discard resolveRepoBackends(
            composed, repos, outsideWs, identity, gitBin)
        except StoreRoutingError as err:
          raised = true
          check err.msg.contains("teamlib")
        check raised
