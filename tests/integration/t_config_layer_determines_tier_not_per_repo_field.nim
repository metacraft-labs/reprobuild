## Unified-Locking-And-Hooks HL-1 (§4, §4.1) — a repo's TIER is an OUTPUT of
## the composing configuration layers, NOT a per-repo ``visibility`` field.
##
## The load-bearing inversion: which LAYER declares a repo fixes its tier
## (tier-by-layer). A repo NAMED only in a private/personal/system layer can
## NEVER appear in the public committed lock — the public layer simply never
## names it. Declaring it in the public layer is the ONLY thing that makes it
## public.
##
## We drive the composed configuration plane (``resolveRepoBackends`` over a
## ``ComposedRouting``, the HL-1 overload that replaces the single visibility-
## keyed ``[locking]`` read) with a repo whose PER-REPO field says
## ``wvPublic``, and assert:
##   1. When a PRIVATE-layer (VCS-private, layer 5) NAMED route claims the repo,
##      it resolves to the PERSONAL tier with a real private backend — NOT the
##      public committed lock — even though ``ResolvedRepo.visibility`` is
##      ``wvPublic``. It is therefore structurally absent from ``repro.lock``
##      (which only ever holds the public / committed-lock partition).
##   2. The declaring LAYER is attributed as ``vcs-private`` (layer 5), proving
##      the tier came from the layer and not the repo field.
##   3. Re-declaring the SAME repo in the PUBLIC layer (a named public route in
##      the parent-workspace layer) is what — and the only thing that — makes it
##      public: it then resolves to ``committed-lock`` / ``store == nil``.
##
## Falsifiable: if resolution fell back to the per-repo ``ResolvedRepo.visibility``
## field (``wvPublic`` here) instead of the declaring layer, assertion (1) would
## resolve to ``committed-lock`` and the personal-tier + private-backend checks
## would fail — the private repo would LEAK into the public lock partition.
## Confirmed by making the composed overload ignore ``repos`` claims and key on
## ``repo.visibility``: (1) then reads ``committed-lock`` and trips.
##
## Hermetic: temp workspace, external-CLI stub as the private backend; nothing
## touches ``$HOME`` or a shared cache. Skip rule: ``git`` missing on PATH.

import std/[options, os, osproc, strutils, tables, tempfiles, unittest]

import repro_lock_store
import repro_cli_support
import repro_workspace_manifests
import git_tool

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc writeStubCli(path: string) =
  writeFile(path, """#!/usr/bin/env bash
set -euo pipefail
db="${DB_DIR:?DB_DIR unset}"
op="$1"; key="$2"
safe=$(printf '%s' "$key" | tr '/' '_')
if [ "$op" = "put" ]; then
  json=$(cat)
  val=$(printf '%s' "$json" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
  printf '%s' "$val" > "$db/$safe"
  exit 0
elif [ "$op" = "get" ]; then
  if [ -f "$db/$safe" ]; then
    val=$(cat "$db/$safe")
    printf '{"schema":"reprobuild.lockstore.external-cli.v1","found":true,"value":"%s"}' "$val"
  else
    printf '{"schema":"reprobuild.lockstore.external-cli.v1","found":false}'
  fi
  exit 0
fi
echo "unknown op: $op" >&2
exit 1
""")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc mkRepo(name, path: string; v: WorkspaceVisibility): ResolvedRepo =
  ResolvedRepo(name: name, path: path, visibility: v)

suite "HL-1 — tier is determined by the declaring layer, not a per-repo field":

  test "t_config_layer_determines_tier_not_per_repo_field":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let ws = createTempDir("repro-hl1-tierbylayer-", "")
      defer: removeDir(ws)

      let db = ws / "personal-db"
      createDir(db)
      let stub = ws / "personal-store.sh"
      writeStubCli(stub)
      putEnv("DB_DIR", db)
      defer: delEnv("DB_DIR")

      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # The repo's PER-REPO field says PUBLIC. Under a naive tier=visibility
      # model this would land in the public committed lock.
      let repos = @[mkRepo("shhh", "shhh", wvPublic)]

      # ---- (1) a PRIVATE-layer NAMED route claims the repo --------------
      # A layer-5 (VCS-private) route that NAMES ``shhh`` at the personal tier.
      let composedPrivate = ComposedRouting(routes: @[
        ComposedRoute(
          tier: wvPersonal,
          entry: LockingRouteEntry(visibility: "personal",
            backend: "external-cli", program: some(stub), repos: @["shhh"]),
          layer: clkVcsPrivate,
          source: ws / ".git" / "repro" / "config.toml",
          repos: @["shhh"])])

      let asgPrivate = resolveRepoBackends(
        composedPrivate, repos, ws, identity, gitBin)
      check asgPrivate.len == 1
      let a = asgPrivate[0]
      # Tier is PERSONAL (from the layer), NOT public (the per-repo field).
      check a.visibility == wvPersonal
      check lockingTierLabel(a.visibility) == "personal"
      # A REAL private backend — never the public committed lock.
      check a.backendKind == "external-cli"
      check not a.store.isNil
      check a.backendKind != "committed-lock"

      # ---- (2) the declaring layer is attributed correctly --------------
      check a.declaringLayer == clkVcsPrivate
      check layerLabel(a.declaringLayer) == "vcs-private"

      # ---- structural: the private repo cannot be a public/committed-lock
      #      partition member. Its record goes to its OWN private backend. ---
      var shas = initTable[string, string]()
      shas["shhh"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      let outcomes = recordWorkspaceParticipation(asgPrivate, "demo", shas)
      check outcomes.len == 1
      check outcomes[0].recorded          # written to the private backend
      # The record lives in the private DB, not any public medium.
      check fileExists(db / ("lock_demo_shhh_" & shas["shhh"]))

      # ---- (3) ONLY re-declaring it in the PUBLIC layer makes it public --
      let composedPublic = ComposedRouting(routes: @[
        ComposedRoute(
          tier: wvPublic,
          entry: LockingRouteEntry(visibility: "public",
            backend: "committed-file", repos: @["shhh"]),
          layer: clkParentWorkspace,
          source: ws / ".repro-workspace.toml",
          repos: @["shhh"])])
      let asgPublic = resolveRepoBackends(
        composedPublic, repos, ws, identity, gitBin)
      check asgPublic.len == 1
      # Now — and only now — it is public. committed-file is the public
      # committed-lock medium the public partition writes.
      check asgPublic[0].visibility == wvPublic
      check asgPublic[0].backendKind == "committed-file"
      check asgPublic[0].declaringLayer == clkParentWorkspace
