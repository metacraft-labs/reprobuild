## output_cleanup.nim
##
## Owned-effect-claim output cleanup executor (milestone M84).
##
## The provider graph refresh already diffs the previous and new graph fragments
## and records, in `ProviderRefreshReport.staleEffects`, one `StaleOwnedEffect`
## per `OwnedEffectClaim` that a vanished or replaced edge used to own — each
## carrying the claim's `CleanupPolicy` (see `recordReplacement` /
## `pruneFragmentAt` in `runtime.nim`). Those cleanup candidates were, until this
## module, written and then dropped: nothing deleted the orphaned build output.
##
## This module consumes the candidates and removes the orphaned outputs on disk,
## honoring the ownership and safety rules mandated by the "Graph Replacement And
## Pruning" and "Failure Semantics" sections of
## `reprobuild-specs/Project-Provider-Graph-Protocol.md`:
##
##   * only `cplDeleteWhenUnclaimed` file/directory effects are auto-deleted;
##     `cplRequireExplicitDestroy` / `cplNeverDeleteAutomatically` are retained,
##     and `cplKeepAsGarbageCollectable` is left in place for output GC;
##   * an effect whose `effectKey` is still claimed by a surviving fragment is
##     retained (shared / re-claimed ownership);
##   * a resolved path that escapes the project root is refused — Reprobuild
##     never deletes outside the tree it owns;
##   * cleanup is idempotent: an already-absent output is a no-op success.
##
## Non-file effect kinds (`oekService`, `oekSystemUser`, `oekDatabase`,
## `oekResource`) are intentionally out of scope here — they belong to the
## resource-state planner.

import std/[os, sets, algorithm, strutils]
import ./types

type
  OutputCleanupOutcome* = enum
    ocoDeleted            ## the orphaned output was removed from disk
    ocoAlreadyAbsent      ## nothing on disk to remove (idempotent no-op)
    ocoWouldDelete        ## dry-run: this output would be deleted
    ocoSkippedPolicy      ## cleanupPolicy forbids automatic deletion
    ocoSkippedShared      ## a surviving fragment still claims this effect
    ocoSkippedKind        ## not a file/directory effect (service/user/db/...)
    ocoSkippedNotEmpty    ## directory still holds entries not owned by the graph
    ocoRefusedOutsideRoot ## resolved path escapes the project root — refused
    ocoFailed             ## deletion attempted but the OS operation failed

  OutputCleanupAction* = object
    invocationKey*: string      ## owning invocation of the vanished claim
    claim*: OwnedEffectClaim    ## the stale claim being considered
    resolvedPath*: string       ## absolute path (empty when refused pre-resolve)
    outcome*: OutputCleanupOutcome
    detail*: string             ## human diagnostic for skips / refusals / failures

  OutputCleanupResult* = object
    actions*: seq[OutputCleanupAction]
    deleted*: int               ## outputs actually removed
    alreadyAbsent*: int         ## delete-decisions whose target was already gone
    wouldDelete*: int           ## dry-run delete-decisions
    skipped*: int               ## retained by policy / sharing / kind / non-empty
    refused*: int               ## refused for escaping the project root
    failed*: int                ## OS deletion failures

proc isFileEffectKind(kind: OwnedEffectKind): bool =
  ## File-shaped effects this executor is allowed to delete. Everything else is
  ## a live-resource concern handled elsewhere.
  kind in {oekFile, oekDirectory, oekOpaqueDirectoryMember}

proc survivingEffectKeys(snapshot: ProviderGraphSnapshot): HashSet[string] =
  ## effectKeys still owned by any live fragment after the refresh. A stale
  ## effect whose key appears here is shared or was immediately re-claimed by a
  ## replacement fragment and must be retained.
  result = initHashSet[string]()
  for fragment in snapshot.fragments:
    for claim in fragment.effectClaims:
      result.incl(effectKey(claim))

proc resolveWithinRoot(projectRoot, identity: string;
                       resolved: var string): bool =
  ## Resolve a claim identity (a declared output path, normally project-relative)
  ## to an absolute, normalized path and confirm it is *strictly* inside
  ## `projectRoot`. Returns false — after setting a best-effort `resolved` for
  ## diagnostics — when the path is the root itself or escapes it (absolute
  ## elsewhere, or `..` traversal). Symlinks are removed as links, not followed,
  ## so a symlinked output cannot be used to delete outside the root.
  let rootAbs = absolutePath(projectRoot).normalizedPath
  let raw = if identity.isAbsolute: identity else: projectRoot / identity
  resolved = absolutePath(raw).normalizedPath
  resolved.len > rootAbs.len and resolved.startsWith(rootAbs & $DirSep)

proc dirIsEmpty(path: string): bool =
  for _ in walkDir(path):
    return false
  true

proc planOutputCleanup*(report: ProviderRefreshReport;
                        projectRoot: string): seq[OutputCleanupAction] =
  ## Decide, without touching the filesystem, what the executor would do for each
  ## stale effect. Skipped / refused decisions are emitted first; the
  ## delete-plan follows in execution order — files (and opaque members) before
  ## directories, and directories deepest-first so a claimed parent is only
  ## considered after owned children beneath it are gone.
  let surviving = survivingEffectKeys(report.snapshot)
  var seenKeys = initHashSet[string]()
  var files, dirs: seq[OutputCleanupAction]
  for stale in report.staleEffects:
    let claim = stale.claim
    let key = effectKey(claim)
    # The same effect can be reported twice (a fragment replacement plus an
    # ancestor prune). Consider each effect once.
    if key in seenKeys:
      continue
    seenKeys.incl(key)
    var act = OutputCleanupAction(invocationKey: stale.invocationKey, claim: claim)
    if not isFileEffectKind(claim.kind):
      act.outcome = ocoSkippedKind
      act.detail = "effect kind " & $claim.kind & " is not a build output"
      result.add(act)
    elif claim.cleanupPolicy != cplDeleteWhenUnclaimed:
      act.outcome = ocoSkippedPolicy
      act.detail = "cleanupPolicy " & $claim.cleanupPolicy & " forbids auto-delete"
      result.add(act)
    elif key in surviving:
      act.outcome = ocoSkippedShared
      act.detail = "effect still claimed by a surviving fragment"
      result.add(act)
    else:
      var resolved: string
      if not resolveWithinRoot(projectRoot, claim.identity, resolved):
        act.resolvedPath = resolved
        act.outcome = ocoRefusedOutsideRoot
        act.detail = "resolved path escapes project root " & projectRoot
        result.add(act)
      else:
        act.resolvedPath = resolved
        act.outcome = ocoWouldDelete
        if claim.kind == oekDirectory:
          dirs.add(act)
        else:
          files.add(act)
  dirs.sort(proc (a, b: OutputCleanupAction): int =
    cmp(b.resolvedPath.len, a.resolvedPath.len))
  result.add(files)
  result.add(dirs)

proc tally(r: var OutputCleanupResult; outcome: OutputCleanupOutcome) =
  case outcome
  of ocoDeleted: inc r.deleted
  of ocoAlreadyAbsent: inc r.alreadyAbsent
  of ocoWouldDelete: inc r.wouldDelete
  of ocoRefusedOutsideRoot: inc r.refused
  of ocoFailed: inc r.failed
  of ocoSkippedPolicy, ocoSkippedShared, ocoSkippedKind, ocoSkippedNotEmpty:
    inc r.skipped

proc applyOutputCleanup*(report: ProviderRefreshReport; projectRoot: string;
                         dryRun = false): OutputCleanupResult =
  ## Execute the cleanup plan produced by `planOutputCleanup`. With `dryRun`,
  ## delete-decisions are left as `ocoWouldDelete` and nothing is removed.
  result.actions = planOutputCleanup(report, projectRoot)
  for act in result.actions.mitems:
    if act.outcome == ocoWouldDelete and not dryRun:
      try:
        if act.claim.kind == oekDirectory:
          if symlinkExists(act.resolvedPath):
            removeFile(act.resolvedPath)          # remove the link, not its target
            act.outcome = ocoDeleted
          elif dirExists(act.resolvedPath):
            if dirIsEmpty(act.resolvedPath):
              removeDir(act.resolvedPath)
              act.outcome = ocoDeleted
            else:
              act.outcome = ocoSkippedNotEmpty
              act.detail = "directory not empty after member cleanup"
          else:
            act.outcome = ocoAlreadyAbsent
        else:
          if fileExists(act.resolvedPath) or symlinkExists(act.resolvedPath):
            removeFile(act.resolvedPath)
            act.outcome = ocoDeleted
          elif dirExists(act.resolvedPath):
            act.outcome = ocoFailed
            act.detail = "declared a file/member but found a directory on disk"
          else:
            act.outcome = ocoAlreadyAbsent
      except OSError as e:
        act.outcome = ocoFailed
        act.detail = e.msg
    result.tally(act.outcome)

proc summaryLine*(r: OutputCleanupResult): string =
  ## One-line human summary for the build log. Empty when there is nothing worth
  ## reporting (no deletions, refusals, or failures).
  if r.deleted == 0 and r.refused == 0 and r.failed == 0 and r.wouldDelete == 0:
    return ""
  var parts: seq[string]
  if r.wouldDelete > 0:
    parts.add($r.wouldDelete & " orphaned output(s) would be cleaned")
  if r.deleted > 0:
    parts.add("cleaned " & $r.deleted & " orphaned output(s)")
  if r.skipped > 0:
    parts.add($r.skipped & " retained")
  if r.refused > 0:
    parts.add($r.refused & " refused (outside root)")
  if r.failed > 0:
    parts.add($r.failed & " failed")
  parts.join(", ")
