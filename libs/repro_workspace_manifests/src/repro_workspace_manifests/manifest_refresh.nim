## repro_workspace_manifests/manifest_refresh.nim
##
## M10 — Manifest-layer refresh helper. Fast-forwards every ``url``-
## backed manifest layer that has already been acquired by M8's
## composer, so a subsequent ``composeManifestLayers`` invocation reads
## the freshest available manifest data.
##
## The spec is explicit
## (``Workspace-And-Develop-Mode.md`` §"Manifest Auto-Refresh"):
##
##   "Before any reconciliation of participating-repo state, the sync
##   command fast-forwards every configured manifest layer."
##
## This helper exposes the refresh as a callable entry point so:
##
## - ``repro workspace sync`` (M10) invokes it as the first step of
##   reconciliation.
## - The M19a auto-refresh hook can invoke the SAME proc when an
##   incoming ``git pull`` on a participating repo signals that the
##   manifest may have advanced.
##
## Policy mirror — for each layer:
##
## - ``local_path``-backed layers: skipped (they describe an in-tree
##   manifest the user maintains; the workspace does not own its
##   refresh cadence).
## - ``url``-backed layers: when the on-disk checkout exists, schedule
##   a ``bakWorkspaceVcs.fetch`` action + a fast-forward of the
##   currently checked-out branch. When the checkout does NOT exist
##   yet, defer to ``composeManifestLayers`` (the first sync of a
##   workspace creates it; this helper only refreshes).
## - When the layer's branch cannot fast-forward (operator has local
##   edits on the manifest checkout, or the branch has diverged), the
##   refresh records a ``skipped`` outcome and continues with the
##   remaining layers. Failing here would block sync; the spec calls
##   this out as a known case (a local manifest edit must be resolved
##   by hand).

import std/[options, os, osproc, strutils, tables]

import types
import resolver
import reader

import repro_build_engine
import git_tool
import git_actions

type
  ManifestLayerRefreshStatus* = enum
    ## What happened to one manifest layer during refresh.
    ##
    ## ``mrsRefreshed``     — fetch + fast-forward succeeded; manifest
    ##                        checkout advanced (or was already current
    ##                        but we re-confirmed via a fetch).
    ## ``mrsUpToDate``      — no change after the fetch; manifest already
    ##                        carries the remote tip.
    ## ``mrsSkippedLocal``  — ``local_path``-backed layer (not the
    ##                        workspace's job to refresh).
    ## ``mrsSkippedAbsent`` — ``url``-backed but on-disk checkout does
    ##                        not exist yet; the composer creates it on
    ##                        the next ``composeManifestLayers`` pass.
    ## ``mrsSkippedDirty``  — refresh refused because the manifest
    ##                        checkout has uncommitted edits.
    ## ``mrsSkippedDivergent`` — refresh refused because the manifest
    ##                        branch could not fast-forward.
    ## ``mrsFailed``        — the fetch action itself failed (no remote,
    ##                        unreachable, etc.). Recorded but does NOT
    ##                        abort sync — the planner reads whatever
    ##                        manifest data is on disk.
    mrsRefreshed
    mrsUpToDate
    mrsSkippedLocal
    mrsSkippedAbsent
    mrsSkippedDirty
    mrsSkippedDivergent
    mrsFailed

  ManifestLayerRefreshEntry* = object
    ## One per layer in the workspace.toml, in source order.
    ## ``provenance`` is the URL or local path (matches the
    ## ``manifestLayer`` field M8 stamps onto each ``ResolvedRepo``).
    ## ``layerPath`` is the on-disk path of the checkout (when known).
    ## ``beforeSha`` / ``afterSha`` carry the manifest checkout's HEAD
    ## SHA before and after the refresh; equal SHAs mean "no advance"
    ## (the layer was already at the remote tip).
    index*: int
    provenance*: string
    layerPath*: string
    status*: ManifestLayerRefreshStatus
    beforeSha*: string
    afterSha*: string
    diagnostic*: string

  ManifestRefreshReport* = object
    workspaceRoot*: string
    workspaceTomlPath*: string
    layers*: seq[ManifestLayerRefreshEntry]

proc manifestLayerStatusTag*(status: ManifestLayerRefreshStatus): string =
  case status
  of mrsRefreshed: "refreshed"
  of mrsUpToDate: "up_to_date"
  of mrsSkippedLocal: "skipped_local_path"
  of mrsSkippedAbsent: "skipped_absent"
  of mrsSkippedDirty: "skipped_dirty"
  of mrsSkippedDivergent: "skipped_divergent"
  of mrsFailed: "failed"

proc sanitizeForPath(raw: string): string =
  ## Mirrors compose.nim's sanitizer so we can recover the on-disk
  ## directory name a previous ``acquireUrlLayer`` chose. We can't
  ## import the helper directly (it's module-private to compose.nim and
  ## the design rule there says compose is the only owner of the layer
  ## acquisition path).
  var raw1 = newStringOfCap(raw.len)
  for ch in raw:
    case ch
    of 'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_': raw1.add(ch)
    else: raw1.add('-')
  var collapsed = newStringOfCap(raw1.len)
  var prevDash = false
  for ch in raw1:
    if ch == '-':
      if not prevDash: collapsed.add(ch)
      prevDash = true
    else:
      collapsed.add(ch)
      prevDash = false
  if collapsed.len > 80:
    collapsed.setLen(80)
  result = collapsed.strip(chars = {'-'}, leading = true, trailing = true)
  if result.len == 0:
    result = "layer"

proc layerDirName(index: int; entry: ManifestLayer): string =
  let urlOrLocal =
    if entry.url.isSome and entry.url.get().len > 0: entry.url.get()
    elif entry.local_path.isSome and entry.local_path.get().len > 0:
      entry.local_path.get()
    else: "layer"
  "manifests-" & $index & "-" & sanitizeForPath(urlOrLocal)

proc q(value: string): string = quoteShell(value)

proc runGit(identity: GitToolIdentity;
            args: openArray[string]): tuple[code: int; output: string] =
  ## Same pattern M9 uses (``revParse`` in repro_cli_support):
  ## ``execCmdEx`` with the identity-bound git binary. We thread
  ## ``poStdErrToStdOut`` so the diagnostic captures both streams.
  var cmd = q(identity.binaryPath)
  for arg in args:
    cmd.add(" ")
    cmd.add(q(arg))
  let res = execCmdEx(cmd, options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc headSha(identity: GitToolIdentity; repoPath: string): string =
  let res = runGit(identity, ["-C", repoPath, "rev-parse", "HEAD"])
  if res.code == 0: res.output.strip() else: ""

proc currentBranch(identity: GitToolIdentity; repoPath: string): string =
  let res = runGit(identity, ["-C", repoPath, "symbolic-ref", "--short",
    "-q", "HEAD"])
  if res.code == 0: res.output.strip() else: ""

proc isClean(identity: GitToolIdentity; repoPath: string): bool =
  let res = runGit(identity, ["-C", repoPath, "status", "--porcelain"])
  res.code == 0 and res.output.strip().len == 0

proc canFastForward(identity: GitToolIdentity;
                    repoPath, localRef, remoteRef: string): bool =
  ## True iff ``localRef`` is an ancestor of ``remoteRef`` — i.e.
  ## ``git merge --ff-only`` would succeed. We use ``merge-base
  ## --is-ancestor`` which returns 0 on yes, 1 on no.
  if localRef.len == 0 or remoteRef.len == 0:
    return false
  let res = runGit(identity,
    ["-C", repoPath, "merge-base", "--is-ancestor", localRef, remoteRef])
  res.code == 0

proc refreshOneUrlLayer(identity: GitToolIdentity;
                        workspaceRoot, dotRepo: string;
                        layerIdx: int;
                        entry: ManifestLayer): ManifestLayerRefreshEntry =
  result.index = layerIdx
  result.provenance = entry.url.get()
  let target = dotRepo / layerDirName(layerIdx, entry)
  result.layerPath = target
  if not dirExists(target):
    result.status = mrsSkippedAbsent
    return

  let beforeSha = headSha(identity, target)
  result.beforeSha = beforeSha

  if not isClean(identity, target):
    result.status = mrsSkippedDirty
    result.afterSha = beforeSha
    result.diagnostic =
      "manifest checkout has uncommitted edits; refresh skipped"
    return

  let branch = currentBranch(identity, target)
  if branch.len == 0:
    # Detached HEAD on a manifest layer. Don't try to fast-forward —
    # the operator is mid-investigation. Treat as up-to-date wrt sync's
    # responsibilities so we don't block reconciliation.
    result.status = mrsSkippedDivergent
    result.afterSha = beforeSha
    result.diagnostic =
      "manifest checkout is in detached HEAD; refresh skipped"
    return

  # Schedule the fetch via the M2 fetch action so the engine sees the
  # work + receipt the rest of the workspace VCS pipeline produces.
  let receiptDir = dotRepo / "engine-cache" / "manifest-refresh-receipts"
  createDir(receiptDir)
  let receiptPath = receiptDir / ("manifest-fetch-" & $layerIdx & ".receipt")
  var action = gitFetchAction(
    "m10-manifest-fetch-" & $layerIdx,
    identity,
    remoteName = "origin",
    repoPath = target,
    receiptPath = receiptPath,
    cacheable = false)
  action.cwd = workspaceRoot
  let cacheRoot = dotRepo / "engine-cache"
  var config = defaultBuildEngineConfig(cacheRoot)
  config.suppressTrace = true
  let res = runBuild(graph([action]), config)
  if res.results.len != 1 or
      res.results[0].status notin {asSucceeded, asCacheHit, asUpToDate}:
    let outcome =
      if res.results.len > 0: res.results[0]
      else: ActionResult(status: asFailed, reason: "no-result")
    result.status = mrsFailed
    result.afterSha = beforeSha
    result.diagnostic = "fetch failed: status=" & $outcome.status &
      " reason=" & outcome.reason &
      (if outcome.stderr.len > 0: " stderr=" & outcome.stderr else: "")
    return

  # Try a fast-forward. ``origin/<branch>`` is the canonical upstream
  # for the layer's checked-out branch — if the layer had any other
  # arrangement (custom upstream, multiple remotes) the operator
  # already opted out of the simple sync model.
  let remoteTip = block:
    let r = runGit(identity, ["-C", target, "rev-parse",
      "refs/remotes/origin/" & branch])
    if r.code == 0: r.output.strip() else: ""
  if remoteTip.len == 0:
    result.status = mrsSkippedDivergent
    result.afterSha = beforeSha
    result.diagnostic =
      "no remote-tracking branch 'origin/" & branch & "' after fetch"
    return
  if remoteTip == beforeSha:
    result.status = mrsUpToDate
    result.afterSha = beforeSha
    return
  if not canFastForward(identity, target, beforeSha, remoteTip):
    result.status = mrsSkippedDivergent
    result.afterSha = beforeSha
    result.diagnostic =
      "manifest branch '" & branch & "' diverged; cannot fast-forward"
    return

  let mergeRes = runGit(identity, ["-C", target, "merge", "--ff-only",
    "refs/remotes/origin/" & branch])
  if mergeRes.code != 0:
    result.status = mrsFailed
    result.afterSha = beforeSha
    result.diagnostic = "merge --ff-only failed: " & mergeRes.output.strip()
    return
  result.afterSha = headSha(identity, target)
  result.status = mrsRefreshed

proc refreshOneLocalLayer(layerIdx: int;
                          entry: ManifestLayer): ManifestLayerRefreshEntry =
  result.index = layerIdx
  result.provenance = entry.local_path.get()
  result.status = mrsSkippedLocal

proc refreshManifestLayers*(workspaceRoot: string):
    ManifestRefreshReport =
  ## Refresh every ``url``-backed manifest layer declared in
  ## ``<workspaceRoot>/.repo/workspace.toml``. Returns a per-layer
  ## report. Raises ``WorkspaceManifestParseError`` if the workspace
  ## TOML itself is missing or malformed; per-layer failures are
  ## reported in the result, NOT raised (sync should continue even if
  ## one layer can't be refreshed).
  let absRoot =
    if isAbsolute(workspaceRoot): workspaceRoot
    else: absolutePath(workspaceRoot)
  result.workspaceRoot = absRoot
  let workspaceTomlPath = absRoot / ".repo" / "workspace.toml"
  result.workspaceTomlPath = workspaceTomlPath
  if not fileExists(workspaceTomlPath):
    # No workspace.toml means M6/M7 single-project mode: nothing to
    # refresh. Return an empty report; the caller treats that as a
    # successful no-op.
    return
  let workspaceLocal = readWorkspaceLocal(workspaceTomlPath)
  if workspaceLocal.manifest.len == 0:
    return
  let identity = ensureGitToolResolvable(tpmPathOnly, getEnv("PATH"))
  let dotRepo = absRoot / ".repo"
  for layerIdx, entry in workspaceLocal.manifest:
    let hasUrl = entry.url.isSome and entry.url.get().len > 0
    if hasUrl:
      result.layers.add(refreshOneUrlLayer(identity, absRoot, dotRepo,
        layerIdx, entry))
    else:
      result.layers.add(refreshOneLocalLayer(layerIdx, entry))
