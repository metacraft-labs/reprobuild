## repro_workspace_manifests/sync_planner.nim
##
## M10 — Sync planner. Pure-policy module that consumes one
## ``ResolvedRepo`` plus a structured ``RepoSyncObservation`` of the
## local checkout's state and emits a ``RepoSyncDecision``: a tag from
## the seven canonical "sync corner cases" the spec enumerates
## (`reprobuild-specs/Workspace-And-Develop-Mode.md` §"Sync Corner
## Cases") plus the minimal mutating action the dispatcher should
## schedule (or refuse-and-report).
##
## Why a separate module
## ---------------------
##
## The classification policy is testable in isolation: given an
## observation, the decision must be deterministic. The dispatcher in
## ``repro_cli_support`` is responsible for *gathering* the observation
## (it runs M2 queries plus a small number of raw ``git rev-parse``
## probes — the same pattern M9 uses) and for *executing* the resulting
## plan (it builds ``bakWorkspaceVcs`` actions and runs them through
## ``runBuild``). The classifier itself never touches the filesystem.
##
## The seven cases (canonical names, identical to the JSON-report tags)
## are:
##
##   - ``clean_at_locked_revision``     — no action
##   - ``clean_fast_forwardable``       — schedule fetch + fast-forward
##   - ``detached_at_locked_revision``  — schedule a branch re-attach
##                                        (no fetch needed; HEAD already
##                                        matches the lock)
##   - ``dirty``                        — refuse + report
##   - ``locally_unpublished``          — refuse + report
##   - ``divergent_feature_branch``     — report only (NOT a failure;
##                                        the spec is explicit that the
##                                        operator may deliberately
##                                        diverge on a feature branch)
##   - ``missing_checkout``             — schedule a clone per placement
##                                        policy
##
## The dispatcher folds the per-repo decisions into a
## ``SyncPlan`` (list of mutating ``bakWorkspaceVcs`` actions) and a
## ``SyncReport`` (per-repo diagnostic).

import std/[strutils]
import resolver

type
  SyncCase* = enum
    ## Canonical seven-case classification, in source order matching the
    ## spec. Each tag has a stable snake_case string form (see
    ## ``syncCaseTag`` below) used as the JSON-report identifier so
    ## downstream tools (M18 / M19) can pattern-match without parsing
    ## the prose.
    scCleanAtLockedRevision
    scCleanFastForwardable
    scDetachedAtLockedRevision
    scDirty
    scLocallyUnpublished
    scDivergentFeatureBranch
    scMissingCheckout

  SyncActionKind* = enum
    ## Discriminator for what the dispatcher should do for a given repo
    ## once the case is decided. ``saNone`` covers every refuse-and-report
    ## or no-op outcome; the planner's ``decision.refusalReason`` carries
    ## the human-facing reason when the case itself was a refusal.
    saNone
    saFetchFastForward
    saAttachBranch
    saClone

  RepoSyncObservation* = object
    ## Everything the planner needs to know about ONE local checkout.
    ## ``exists`` is the load-bearing first probe: when it's false every
    ## other field is ignored and the decision is ``missing_checkout``.
    ##
    ## When ``exists`` is true:
    ## - ``headSha``          — observed HEAD SHA of the working tree.
    ## - ``isClean``          — ``git status --porcelain`` was empty.
    ## - ``currentBranch``    — current branch name, or empty when
    ##                          HEAD is detached.
    ## - ``localBranchTip``   — tip of ``currentBranch`` (when present),
    ##                          else empty.
    ## - ``remoteBranchTip``  — tip of ``origin/<currentBranch>`` (when
    ##                          ``currentBranch`` is non-empty AND a
    ##                          remote-tracking branch exists), else
    ##                          empty.
    ## - ``lockedRevisionTip``— the SHA the manifest's pinned revision
    ##                          actually resolves to in the local clone.
    ##                          For a SHA-pinned manifest this is the
    ##                          manifest revision itself. For a branch-
    ##                          pinned manifest this is the tip of the
    ##                          remote-tracking branch (the same value
    ##                          M9's ``expectedBranchTip`` returns).
    ## - ``hasUnpublishedCommits`` — at least one commit on the current
    ##                          branch is NOT reachable from any remote
    ##                          tracking ref (``git log @{u}..HEAD`` is
    ##                          non-empty, or the published-evidence
    ##                          query says ``isPublished=false``).
    exists*: bool
    headSha*: string
    isClean*: bool
    currentBranch*: string
    localBranchTip*: string
    remoteBranchTip*: string
    lockedRevisionTip*: string
    hasUnpublishedCommits*: bool

  RepoSyncDecision* = object
    ## One repo's classification + chosen mutating action. The
    ## ``message`` field carries a human-facing one-liner the CLI text
    ## renderer emits unchanged; ``observed`` and ``expected`` give the
    ## structured before/after SHAs (when they are meaningful) so the
    ## JSON report can be inspected programmatically.
    name*: string
    path*: string
    syncCase*: SyncCase
    action*: SyncActionKind
    expected*: string
    observed*: string
    branch*: string
    message*: string
    refusalReason*: string

  SyncPlan* = object
    ## The mutating actions the dispatcher must enqueue. Position in
    ## ``decisions`` matches position in ``actions`` ONLY for repos with
    ## ``action != saNone``; the caller correlates by ``repoName``.
    decisions*: seq[RepoSyncDecision]

  SyncReport* = object
    ## Per-repo diagnostic the CLI converts to JSON / stdout text. The
    ## planner returns this alongside ``SyncPlan``; the dispatcher
    ## decorates it with post-execution status (e.g. "fetch succeeded",
    ## "clone failed") before writing ``sync-report.json``.
    decisions*: seq[RepoSyncDecision]

proc syncCaseTag*(syncCase: SyncCase): string =
  ## Stable snake_case identifier embedded in the JSON report. Matches
  ## the names the milestone spec uses verbatim so downstream tools
  ## (M18 / M19 hook handlers) can pattern-match without prose parsing.
  case syncCase
  of scCleanAtLockedRevision: "clean_at_locked_revision"
  of scCleanFastForwardable: "clean_fast_forwardable"
  of scDetachedAtLockedRevision: "detached_at_locked_revision"
  of scDirty: "dirty"
  of scLocallyUnpublished: "locally_unpublished"
  of scDivergentFeatureBranch: "divergent_feature_branch"
  of scMissingCheckout: "missing_checkout"

proc syncActionTag*(action: SyncActionKind): string =
  ## Stable identifier for the planner's action enum, used as the JSON
  ## report's ``action`` field. ``none`` covers both pure no-ops and
  ## refuse-and-report outcomes — the ``syncCase`` field disambiguates.
  case action
  of saNone: "none"
  of saFetchFastForward: "fetch_fast_forward"
  of saAttachBranch: "attach_branch"
  of saClone: "clone"

proc sameSha(a, b: string): bool =
  ## SHA equality that tolerates an abbreviated prefix on either side.
  ## Mirrors M9's tolerant compare: a 7-39 character abbreviation pins
  ## the long form whenever it's a strict prefix. Both sides must be
  ## non-empty; an empty string matches NOTHING (the caller relies on
  ## that to distinguish "observed=empty" from a legitimate match).
  if a.len == 0 or b.len == 0:
    return false
  if a == b:
    return true
  a.startsWith(b) or b.startsWith(a)

proc classifyRepoState*(resolved: ResolvedRepo;
                        observation: RepoSyncObservation): RepoSyncDecision =
  ## Map ``(resolved, observation)`` to one of the seven canonical
  ## cases. The decision logic deliberately runs in a fixed priority
  ## order:
  ##
  ## 1. ``missing_checkout``           (the directory doesn't exist)
  ## 2. ``dirty``                      (working tree has uncommitted changes)
  ## 3. ``locally_unpublished``        (HEAD or its history has commits not
  ##                                    reachable from any remote ref)
  ## 4. ``clean_at_locked_revision``   (HEAD already matches the lock)
  ## 5. ``detached_at_locked_revision``(HEAD matches the lock but no branch)
  ## 6. ``clean_fast_forwardable``     (current branch can fast-forward to
  ##                                    the locked tip)
  ## 7. ``divergent_feature_branch``   (everything else — the operator is
  ##                                    on a feature branch that has its
  ##                                    own history vs the lock)
  result.name = resolved.name
  result.path = resolved.path
  result.expected = resolved.revision
  result.branch = observation.currentBranch

  if not observation.exists:
    result.syncCase = scMissingCheckout
    result.action = saClone
    result.message = "scheduling clone of '" & resolved.path & "' from " &
      resolved.fetchUrl & " @ " & resolved.revision
    return

  result.observed = observation.headSha

  if not observation.isClean:
    result.syncCase = scDirty
    result.action = saNone
    result.refusalReason =
      "working tree has uncommitted changes; refused (operator must commit, stash, or discard)"
    result.message = "refusing to sync dirty checkout at '" & resolved.path & "'"
    return

  # Locally-unpublished commits beat the fast-forward / divergence
  # check: even a clean tree that's strictly ahead of the lock and the
  # remote tracking branch is a refusal — the operator owns work that
  # has not yet been published, and a sync would surprise them.
  if observation.hasUnpublishedCommits:
    result.syncCase = scLocallyUnpublished
    result.action = saNone
    result.refusalReason =
      "local commits are not present on any remote-tracking branch; refused (operator must push or rebase first)"
    result.message = "refusing to sync unpublished checkout at '" & resolved.path & "'"
    return

  # The "locked revision" is whatever the manifest's revision resolves
  # to in the local clone (a SHA pin → itself; a branch pin → the tip
  # of the remote-tracking branch). When the dispatcher can't resolve
  # the lock locally, ``lockedRevisionTip`` is empty and we fall
  # straight to the divergent-feature-branch arm.
  let lockedTip = observation.lockedRevisionTip

  if lockedTip.len > 0 and sameSha(observation.headSha, lockedTip):
    if observation.currentBranch.len == 0:
      # Detached HEAD that happens to point at the locked revision.
      # Re-attach the checkout to the manifest's pinned branch (when
      # the manifest names one) so the steady state is on-branch.
      result.syncCase = scDetachedAtLockedRevision
      result.action = saAttachBranch
      result.message = "attaching '" & resolved.path & "' branch=" &
        resolved.revision & " at " & lockedTip
      return
    result.syncCase = scCleanAtLockedRevision
    result.action = saNone
    result.message = "clean at locked revision: '" & resolved.path & "' @ " &
      lockedTip
    return

  # Fast-forwardable: we're on a branch whose tip matches the locked
  # tip via plain fast-forward — i.e. the locked tip is downstream of
  # what's already in the working tree's branch. The simplest sound
  # test is "the locked tip IS the remote tracking branch's tip and
  # HEAD is reachable from it" — but in the local-only fixture the
  # remote tracking ref and the locked tip are typically the same SHA
  # the manifest pinned, so an exact SHA match on
  # ``remoteBranchTip == lockedTip`` is the load-bearing signal here.
  # The caller's observation pipeline supplies ``hasUnpublishedCommits
  # = false`` whenever HEAD is strictly behind ``origin/<branch>``,
  # which means a fast-forward is safe.
  if observation.currentBranch.len > 0 and lockedTip.len > 0 and
      observation.remoteBranchTip.len > 0 and
      sameSha(observation.remoteBranchTip, lockedTip):
    result.syncCase = scCleanFastForwardable
    result.action = saFetchFastForward
    result.message = "fast-forwarding '" & resolved.path & "' on branch " &
      observation.currentBranch & " → " & lockedTip
    return

  # Everything else: the working tree is clean, has nothing
  # unpublished, but its HEAD does not match the locked tip and the
  # current branch is not a candidate for an unattended fast-forward.
  # The spec is explicit that this is REPORT-ONLY, not a failure: the
  # operator may legitimately be on a feature branch that diverges
  # from the lock.
  result.syncCase = scDivergentFeatureBranch
  result.action = saNone
  result.message = "feature branch '" & observation.currentBranch &
    "' at '" & resolved.path & "' diverges from locked revision"
  return

proc planSync*(resolved: openArray[ResolvedRepo];
               observations: openArray[RepoSyncObservation]):
              tuple[plan: SyncPlan; report: SyncReport] =
  ## Drive ``classifyRepoState`` over every (resolved, observation)
  ## pair. ``resolved.len`` MUST equal ``observations.len`` — the
  ## dispatcher always gathers an observation for every declared repo
  ## (a "directory does not exist" observation still counts; it carries
  ## ``exists=false``).
  if resolved.len != observations.len:
    raise newException(ValueError,
      "planSync requires one observation per resolved repo (got " &
        $resolved.len & " repos and " & $observations.len & " observations)")
  for i, repo in resolved:
    let decision = classifyRepoState(repo, observations[i])
    result.plan.decisions.add(decision)
    result.report.decisions.add(decision)
