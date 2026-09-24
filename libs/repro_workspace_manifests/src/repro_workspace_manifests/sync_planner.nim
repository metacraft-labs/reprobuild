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
    scForcePushRebase
    scFetchFailed
      ## The pre-classification fetch for this repo did not succeed, so
      ## every remote-derived field in the observation describes the state
      ## of the world at some UNKNOWN earlier time. No verdict may be
      ## rendered from it -- least of all a reassuring one. See the guard
      ## at the top of ``classifyRepoState``.

  SyncActionKind* = enum
    ## Discriminator for what the dispatcher should do for a given repo
    ## once the case is decided. ``saNone`` covers every refuse-and-report
    ## or no-op outcome; the planner's ``decision.refusalReason`` carries
    ## the human-facing reason when the case itself was a refusal.
    saNone
    saFetchFastForward
    saAttachBranch
    saClone
    saForcePushRebase

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
    ## - ``attachableBranches`` — branch names for which ``git switch <name>``
    ##                          would succeed AND land the checkout exactly on
    ##                          ``lockedRevisionTip``. The dispatcher resolves
    ##                          this (it is the only party that may touch git);
    ##                          see ``observeRepoForSync`` for the exact tests,
    ##                          which cover local tips, shadowed names, orphan
    ##                          remote-tracking refs, and ambiguous DWIM.
    ##                          Local names come first. Empty when nothing
    ##                          names the locked revision, which is a
    ##                          legitimate steady state, not an error — the
    ##                          planner then leaves the checkout detached.
    ##
    ## The observation deliberately carries NO workspace-wide metadata. It
    ## used to also carry the M16 ``feature_started`` mark and the recorded
    ## workspace branch, which together suppressed the fast-forward arm on the
    ## marked branch. Both are gone: a repo's sync decision is a function of
    ## that repo's own git state and the manifest's pin for it, and nothing
    ## else. Whether the operator declared a feature "started" cannot make a
    ## teammate's pushed commit unwanted.
    exists*: bool
    headSha*: string
    isClean*: bool
    currentBranch*: string
    localBranchTip*: string
    remoteBranchTip*: string
    lockedRevisionTip*: string
    hasUnpublishedCommits*: bool
    hasForcePushedCommits*: bool
    forcePushedBaseSha*: string
    attachableBranches*: seq[string]
    fetchFailed*: bool
      ## The dispatcher's pre-classification fetch for THIS repo did not
      ## succeed. Every remote-derived field above
      ## (``remoteBranchTip``, ``lockedRevisionTip``,
      ## ``hasUnpublishedCommits``, ``hasForcePushedCommits``,
      ## ``remoteHistoryDisjoint``) is then a reading of stale
      ## remote-tracking refs, not of the remote. The planner refuses on
      ## this flag rather than classifying: a checkout 175 commits behind a
      ## rewritten remote reads EXACTLY like a checkout that is current, and
      ## reporting the reassuring one of two indistinguishable states as
      ## fact is how a dead workspace gets called clean.
    fetchDiagnostic*: string
      ## Why the fetch failed, verbatim from the dispatcher, so the refusal
      ## names the real cause instead of the symptom.
    remoteHistoryDisjoint*: bool
      ## HEAD shares NO history with the remote: the merge-base of HEAD and
      ## the remote's trunk tip is empty. On a branch with a remote
      ## counterpart that counterpart answers the force-push question
      ## directly; on a LOCAL-ONLY branch there is no counterpart to compare
      ## against, and this is the signal that the history the branch was cut
      ## from no longer exists upstream -- i.e. the remote was rewritten
      ## under it. Without this, such a branch fell through to
      ## ``locally_unpublished``, whose remedy is "push", which republishes
      ## the dead history.

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
    forcePushedBaseSha*: string

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
  of scForcePushRebase: "force_push_rebase"
  of scFetchFailed: "fetch_failed"

proc syncActionTag*(action: SyncActionKind): string =
  ## Stable identifier for the planner's action enum, used as the JSON
  ## report's ``action`` field. ``none`` covers both pure no-ops and
  ## refuse-and-report outcomes — the ``syncCase`` field disambiguates.
  case action
  of saNone: "none"
  of saFetchFastForward: "fetch_fast_forward"
  of saAttachBranch: "attach_branch"
  of saClone: "clone"
  of saForcePushRebase: "force_push_rebase"

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

proc looksLikeSha(value: string): bool =
  ## Branch-vs-SHA test for the manifest's ``revision`` field. Same
  ## heuristic the CLI uses: 7-64 lowercase hex characters is a commit
  ## (or an operator's abbreviation of one), anything else is a branch
  ## name. Duplicated rather than imported because this module is
  ## pure-policy and must not depend on the CLI layer.
  if value.len < 7 or value.len > 64:
    return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f'}:
      return false
  true

const wellKnownIntegrationBranches = ["main", "master", "develop", "trunk",
                                      "default"]

proc chooseAttachBranch*(resolved: ResolvedRepo;
                         observation: RepoSyncObservation): string =
  ## Pick the branch a detached-at-the-lock checkout should be re-attached
  ## to, or "" when it must stay detached.
  ##
  ## Workspace-And-Develop-Mode.md §"Branch Preservation Policy" gives the
  ## heuristic order, and every candidate in it is qualified by the SAME
  ## condition — "if its tip matches the locked revision". That condition is
  ## the whole point: a branch name is a convenience, the locked revision is
  ## the correctness boundary, so attaching to a branch that names a
  ## DIFFERENT commit does not preserve the checkout, it moves it. The
  ## candidate list this chooses from (``attachableBranches``) is pre-filtered
  ## on exactly that condition, so every branch here is safe by construction
  ## and this proc only expresses the PREFERENCE among them.
  ##
  ## Order:
  ##   1. the branch the fragment says this repo TRACKS (``resolved.branch``),
  ##      then a legacy ``revision`` that holds a branch name rather than a
  ##      commit — the most meaningful name for this revision in this
  ##      workspace, and the closest thing to the spec's candidate 3
  ##   2. well-known integration branches (spec candidate 4)
  ##   3. any other attachable branch, lowest name first so the choice is
  ##      deterministic across runs and machines (spec candidate 5)
  ##
  ## Spec candidate 2 ("the currently checked out branch") cannot apply: this
  ## runs only for a DETACHED head, which by definition has none. Spec
  ## candidate 1 (the active workspace branch) is deliberately not consulted —
  ## ``RepoSyncObservation`` carries no workspace-wide metadata by design (see
  ## its doc comment), and reinstating it here would undo that. It is a
  ## preference among already-safe candidates, so omitting it cannot pick an
  ## unsafe branch; it can only pick a differently-named safe one.
  if observation.attachableBranches.len == 0:
    return ""
  for preferred in [resolved.branch,
                    if looksLikeSha(resolved.revision): "" else: resolved.revision]:
    if preferred.len == 0: continue
    for candidate in observation.attachableBranches:
      if candidate == preferred:
        return candidate
  for wellKnown in wellKnownIntegrationBranches:
    for candidate in observation.attachableBranches:
      if candidate == wellKnown:
        return candidate
  result = observation.attachableBranches[0]
  for candidate in observation.attachableBranches:
    if candidate < result:
      result = candidate

proc gitRemoteFor(resolved: ResolvedRepo): string =
  ## The GIT remote name a refusal should NAME in its remedy command — the
  ## name the operator will type, not the manifest's ``[[remote]]`` key.
  ## Same mapping ``gitRemoteNameFor`` performs in the dispatcher,
  ## duplicated rather than imported because this module is pure policy and
  ## must not depend on the CLI layer.
  for r in resolved.remotes:
    if r.projectRemote == resolved.projectRemote and r.localName.len > 0:
      return r.localName
  if resolved.projectRemote.len > 0: resolved.projectRemote else: "origin"

proc trunkNameFor(resolved: ResolvedRepo): string =
  ## The branch a rewritten repo's work should be rebased ONTO: the repo's
  ## declared tracking branch, else its manifest revision when that names a
  ## branch rather than a commit.
  if resolved.branch.len > 0: resolved.branch
  elif resolved.revision.len > 0 and not looksLikeSha(resolved.revision):
    resolved.revision
  else: "<trunk>"

proc classifyRepoState*(resolved: ResolvedRepo;
                        observation: RepoSyncObservation;
                        rebaseOnForcePush: bool = false): RepoSyncDecision =
  ## Map ``(resolved, observation)`` to one of the seven canonical
  ## cases. The decision logic deliberately runs in a fixed priority
  ## order:
  ##
  ## 0. ``fetch_failed``              (the pre-classification fetch for
  ##                                    this repo did not succeed, so no
  ##                                    remote-derived field can be trusted)
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
  ##
  ## ``rebaseOnForcePush`` DEFAULTS TO FALSE, and that default is a safety
  ## boundary rather than a stylistic choice. ``saForcePushRebase`` is
  ## executed by ``executeForcePushRebase``, which does ``git reset --hard
  ## <remote>/<branch>`` and only then replays what it can. Whatever the
  ## replay restores, the branch ref HAS been moved onto a history that may
  ## share no commit with the one it was on — a destructive act on the
  ## operator's checkout, so it is subject to RA-9 (preview, then confirm)
  ## and to RA-16's rule that a divergent checkout is report-only-skipped
  ## unless the operator opted in.
  ##
  ## It defaulted to TRUE, and ``parseWorkspaceSyncArgs`` defaulted the flag
  ## to true as well, so a bare ``repro sync`` reset every checkout for which
  ## a force-push had been RECORDED — no preview, no confirmation, and
  ## counted in the digest as an ordinary "updated". Measured on a real
  ## workspace: 12 repos reset by a run whose own summary said ``force-reset
  ## 0, skipped 0``. The refusal text in the force-push arm below has always
  ## told the operator to "run 'repro sync --rebase-on-force-push'", which is
  ## only true advice if the flag is an opt-in; under the old default the
  ## rebase had already happened by the time anyone could read it.
  ##
  ## Consequence: a force-pushed checkout now classifies as
  ## ``scForcePushRebase`` + ``saNone`` — refused and reported — exactly as a
  ## checkout whose branch has no remote counterpart always did.
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

  # FIRST, ahead of every other arm, because it is the arm that says "I do
  # not know". Each arm below reads at least one remote-derived field, and a
  # failed fetch means those fields describe the remote as it was at some
  # unknown earlier time -- possibly before a history rewrite. The arm this
  # guard most directly displaces is ``clean_at_locked_revision``: a
  # checkout whose stale ``origin/<branch>`` still equals its HEAD is
  # indistinguishable from a current one, so without the guard the planner
  # answered "clean at locked revision" for a checkout that was 175 commits
  # dead. There is no safe way to classify unfetched data; the only honest
  # verdict is a refusal that says the fetch is what failed.
  if observation.fetchFailed:
    result.syncCase = scFetchFailed
    result.action = saNone
    result.refusalReason =
      "the pre-classification fetch for '" & resolved.path &
      "' failed, so this checkout's state against the remote is UNKNOWN " &
      "and no 'up to date' verdict can be given for it" &
      (if observation.fetchDiagnostic.len > 0:
         " (" & observation.fetchDiagnostic & ")"
       else: "") &
      "; refused -- restore access to '" & resolved.fetchUrl &
      "' (auth / network / credentials), confirm with 'git -C " &
      resolved.path & " fetch --all --prune', then re-run 'repro sync'"
    result.message = "refusing to classify '" & resolved.path &
      "' on unfetched data"
    return

  if not observation.isClean:
    result.syncCase = scDirty
    result.action = saNone
    # Principle 2 (Interactive-UX-And-Progress.md): name the offender AND a
    # concrete remedy command. The offending checkout is ``resolved.path``;
    # the remedy is to clear the working tree (commit or stash) then re-run
    # sync, or to overwrite it deliberately with ``--force-sync``.
    result.refusalReason =
      "working tree has uncommitted changes; refused — run 'git -C " &
      resolved.path & " stash' (or 'git -C " & resolved.path &
      " commit -a') then 'repro sync', or 'repro sync --force-sync' to discard"
    result.message = "refusing to sync dirty checkout at '" & resolved.path & "'"
    return

  if observation.hasForcePushedCommits or observation.remoteHistoryDisjoint:
    result.syncCase = scForcePushRebase
    # ``remoteBranchTip`` is a HARD requirement: ``executeForcePushRebase``
    # does ``git reset --hard <remote>/<branch>``, so without a remote
    # counterpart for the current branch there is nothing to reset ONTO.
    #
    # ``forcePushedBaseSha`` is a DELIBERATE RESTRAINT, not a limitation of
    # the executor. The executor selects what to replay with ``git cherry``
    # and treats the base as an optional walk limit, so it would run without
    # one. The reason to require it anyway is what its absence MEANS. It is
    # set only alongside ``hasForcePushedCommits``, by a sync that watched
    # the remote ref move under it; when it is empty, the rewrite was
    # inferred from ancestry alone, some time after the fact, and the
    # operator has not been told about it yet. Auto-replaying there would
    # turn the ancestry signal into an unprompted ``git reset --hard`` on a
    # checkout that may carry hundreds of commits of disjoint history. The
    # refusal below names the situation and two non-destructive remedies
    # instead; ``--force-sync`` remains the explicit way to ask for the
    # destructive one.
    let canAutoRebase =
      rebaseOnForcePush and
      observation.remoteBranchTip.len > 0 and
      observation.forcePushedBaseSha.len > 0
    if canAutoRebase:
      result.action = saForcePushRebase
      result.forcePushedBaseSha = observation.forcePushedBaseSha
      result.message = "cherry-picking locally authored commits on top of force-pushed branch at '" & resolved.path & "'"
      return
    result.action = saNone
    if observation.remoteHistoryDisjoint:
      # THE post-rewrite case, and the reason this arm exists at all.
      #
      # A local branch with no ``<remote>/<branch>`` counterpart could not
      # have the force-push question asked of it — the probe ran ``git log
      # <remote>/<branch>..HEAD``, which does not resolve — so it fell
      # through to ``locally_unpublished``, whose remedy is "run git push
      # then repro sync". Post-rewrite that instruction republishes the
      # history the rewrite removed: the single worst thing an operator
      # could be told to do, said in the tool's own voice.
      #
      # What is said instead names the situation, forbids the push
      # explicitly, and points at the two remedies that do not destroy
      # anything.
      result.refusalReason =
        "'" & resolved.path & "' shares no history with its remote: the " &
        "upstream was rewritten and this checkout still carries the old " &
        "history. Refused — do NOT push, that republishes the removed " &
        "history. Rebase the work you own onto the new history " &
        "('git -C " & resolved.path & " fetch --all --prune' then " &
        "'git -C " & resolved.path & " rebase --onto " &
        gitRemoteFor(resolved) & "/" & trunkNameFor(resolved) &
        " <your branch point> " &
        (if observation.currentBranch.len > 0: observation.currentBranch
         else: "HEAD") &
        "'), or discard it with 'repro sync --force-sync'"
      result.message = "refusing to sync '" & resolved.path &
        "': its history is disjoint from the rewritten remote"
      return
    if not rebaseOnForcePush:
      result.refusalReason = "remote branch was force-pushed; refused — " &
        "run 'repro sync --rebase-on-force-push' to rebase your local commits " &
        "on the new history, or 'repro sync --force-sync' to discard local changes"
      result.message = "refusing to sync force-pushed checkout at '" & resolved.path & "'"
      return
    # Force-pushed, the operator wants the rebase, and one of its two
    # inputs is missing. Say WHICH, rather than scheduling an action whose
    # only possible outcome is a failure the operator has to decode.
    result.refusalReason =
      "remote branch was force-pushed, but this checkout cannot be rebased " &
      "automatically: " &
      (if observation.remoteBranchTip.len == 0:
         "branch '" & (if observation.currentBranch.len > 0:
           observation.currentBranch else: "HEAD") &
           "' has no counterpart on remote '" & gitRemoteFor(resolved) &
           "' to replay onto"
       else: "no superseded base commit was recorded to replay from") &
      ". Refused — do NOT push before checking whether the remote history " &
      "was rewritten; rebase manually onto '" & gitRemoteFor(resolved) &
      "/" & trunkNameFor(resolved) & "', or run 'repro sync --force-sync' " &
      "to discard local changes"
    result.message = "refusing to sync force-pushed checkout at '" &
      resolved.path & "': nothing to rebase onto"
    return

  # Locally-unpublished commits beat the fast-forward / divergence
  # check: even a clean tree that's strictly ahead of the lock and the
  # remote tracking branch is a refusal — the operator owns work that
  # has not yet been published, and a sync would surprise them.
  if observation.hasUnpublishedCommits:
    result.syncCase = scLocallyUnpublished
    result.action = saNone
    # Principle 2: name the offending checkout AND the command that resolves
    # it. Publishing (push) the local commits, then re-running sync, makes
    # the workspace reproducible without surprising the operator.
    # The remedy is deliberately NOT an unconditional "push". This text is
    # read at exactly the moment a force-push may have happened, and a bare
    # ``git push`` of a branch whose base the remote no longer has is how
    # the removed history gets republished. ``remoteHistoryDisjoint``
    # already diverts the proven-rewritten case to the force-push arm above;
    # what is left here is the case nobody can prove either way, so the text
    # says what to CHECK before publishing, and names the non-push remedy.
    result.refusalReason =
      "local commits are not present on any remote-tracking branch; refused — " &
      "first confirm the remote history was not rewritten under you " &
      "('git -C " & resolved.path & " fetch --all --prune' then 'git -C " &
      resolved.path & " log --oneline @{u}..HEAD'). If it is intact, publish " &
      "with 'git -C " & resolved.path & " push' then re-run 'repro sync'. If " &
      "it was rewritten, do NOT push — that republishes the removed history; " &
      "rebase onto the new history ('git -C " & resolved.path &
      " pull --rebase') or run 'repro sync --rebase-on-force-push'"
    result.message = "refusing to sync unpublished checkout at '" & resolved.path & "'"
    return

  # The "locked revision" is whatever the manifest's revision resolves
  # to in the local clone (a SHA pin → itself; a branch pin → the tip
  # of the remote-tracking branch). When the dispatcher can't resolve
  # the lock locally, ``lockedRevisionTip`` is empty and we fall
  # straight to the divergent-feature-branch arm.
  let lockedTip = observation.lockedRevisionTip

  # Fast-forwardable: HEAD is behind its OWN upstream (``<remote>/<current
  # branch>``). Syncing the trunk and syncing a feature branch are the SAME
  # operation — only which ref is upstream differs — so both take this one path.
  #
  # This previously also required ``remoteBranchTip == lockedTip`` (the
  # MANIFEST's pinned revision). That holds only when the checked-out branch IS
  # the manifest's branch, so a feature branch could never fast-forward from its
  # own upstream and a teammate's pushed commits never arrived. The M16
  # ``feature_started`` mark then suppressed this arm outright on the marked
  # branch, which made the collaboration case worse rather than better. Both are
  # gone: the sync target is simply the current branch's upstream.
  #
  # ``hasUnpublishedCommits = false`` is the observation pipeline's signal that
  # HEAD is strictly BEHIND its upstream rather than diverged, which is what
  # makes the fast-forward sound.
  #
  # This arm is deliberately checked BEFORE the "clean at locked revision" arm
  # below. A feature branch freshly cut from the trunk has ``headSha ==
  # lockedTip`` on its very first day, so testing the manifest pin first would
  # declare the checkout finished and swallow every commit a teammate pushed to
  # that branch — the same manifest-pin-shadows-the-branch mistake in a
  # different place. When the current branch IS at its own upstream tip this
  # guard is false and control falls through to the pin comparison unchanged.
  if observation.currentBranch.len > 0 and
      observation.remoteBranchTip.len > 0 and
      not observation.hasUnpublishedCommits and
      not sameSha(observation.headSha, observation.remoteBranchTip):
    result.syncCase = scCleanFastForwardable
    result.action = saFetchFastForward
    result.message = "fast-forwarding '" & resolved.path & "' on branch " &
      observation.currentBranch & " → " & observation.remoteBranchTip
    return

  if lockedTip.len > 0 and sameSha(observation.headSha, lockedTip):
    if observation.currentBranch.len == 0:
      # Detached HEAD that happens to point at the locked revision.
      # Re-attach it to a branch that NAMES that revision, so the steady
      # state is on-branch without the checkout moving.
      #
      # This used to attach to the manifest's ``revision`` when that was a
      # branch name and to the literal string "main" otherwise, without ever
      # checking where either one pointed. For a SHA-pinned repo — every
      # vendored reference tree in a real workspace — "main" has almost
      # always moved past the pin, so the re-attach silently dragged the
      # checkout OFF the revision the manifest pinned it to, which is the
      # one thing sync must never do. Being detached at the pin is the
      # CORRECT state for such a repo; the spec's "only leave it detached as
      # a last resort" ranks the alternatives, it does not license moving
      # the checkout to avoid the last resort.
      result.syncCase = scDetachedAtLockedRevision
      let attachTo = chooseAttachBranch(resolved, observation)
      if attachTo.len == 0:
        # Spec §"Detached checkout at the locked revision": leaving it
        # detached is the documented last resort. Report it and move on —
        # NOT a refusal (no ``refusalReason``), because nothing is wrong:
        # the checkout is clean and sits exactly where the manifest says.
        result.action = saNone
        result.message = "leaving '" & resolved.path & "' detached at " &
          lockedTip & " — no branch tip names the locked revision"
        return
      result.action = saAttachBranch
      result.branch = attachTo
      result.message = "attaching '" & resolved.path & "' to branch " &
        attachTo & " at " & lockedTip
      return
    result.syncCase = scCleanAtLockedRevision
    result.action = saNone
    result.message = "clean at locked revision: '" & resolved.path & "' @ " &
      lockedTip
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
               observations: openArray[RepoSyncObservation];
               rebaseOnForcePush: bool = false):
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
    let decision = classifyRepoState(repo, observations[i], rebaseOnForcePush)
    result.plan.decisions.add(decision)
    result.report.decisions.add(decision)

# ---------------------------------------------------------------------------
# `repro sync --mainline` — reconcile a branch with its repo's own mainline.
#
# A SEPARATE decision table from `planSync` above, deliberately. `planSync`
# answers "is this checkout where the lock says it should be", comparing the
# current branch against its own upstream and the locked revision. `--mainline`
# answers a different question — "has trunk moved under my feature branch" —
# against a different ref, and the two tables share no case. Folding them would
# mean a `syncCase` whose meaning depended on a flag, which is exactly the kind
# of overload that makes the report unreadable.
#
# Pure, like its sibling: the caller gathers the observation (fetch, rev-parse,
# merge-base, and the `merge-tree` conflict prediction) and executes the plan.
# Nothing here touches the filesystem, so the whole table is unit-testable.

type
  MainlineSyncFlavor* = enum
    ## How a DIVERGED branch should be integrated. `msfFastForwardOnly` is the
    ## bare `--mainline` default and integrates nothing: it fast-forwards what
    ## can be fast-forwarded and reports the rest (CLI/sync.md §"Without
    ## --rebase or --merge"). The two real flavors are chosen per invocation
    ## because the answer depends on the diff, not on the repository.
    msfFastForwardOnly
    msfRebase
    msfMerge

  MainlineSyncCase* = enum
    mscUpToDate          ## Branch already contains the mainline tip.
    mscFastForwardable   ## Branch is an ancestor of mainline; FF is safe.
    mscIntegrable        ## Diverged, a flavor was chosen, predicted clean.
    mscDiverged          ## Diverged and no flavor chosen — report, don't guess.
    mscConflict          ## Chosen flavor would conflict; repo left untouched.
    mscDirty             ## Uncommitted changes; integration needs a clean tree.
    mscDetachedHead      ## No branch to reconcile.
    mscNoMainlineBranch  ## Fragment declares no `branch` to target.
    mscNoMainlineRef     ## `<remote>/<mainline>` absent after fetching.
    mscMissingCheckout   ## Nothing on disk.

  MainlineSyncAction* = enum
    msaNone
    msaFastForward
    msaRebase
    msaMerge

  MainlineSyncObservation* = object
    ## One repo's git state, relative to ITS mainline. Every field is a fact
    ## the caller measured; the planner adds no I/O of its own.
    exists*: bool
    isClean*: bool
    currentBranch*: string     ## Empty when HEAD is detached.
    headSha*: string
    mainlineBranch*: string    ## The fragment's `branch`; empty if undeclared.
    mainlineTip*: string       ## `<remote>/<mainlineBranch>`; empty if absent.
    mainlineInHead*: bool      ## merge-base --is-ancestor <mainlineTip> HEAD
    headInMainline*: bool      ## merge-base --is-ancestor HEAD <mainlineTip>
    integrationConflicts*: bool
      ## Result of the `merge-tree --write-tree` prediction. Only consulted
      ## when a flavor is chosen AND the repo is diverged AND the tree is
      ## clean; meaningless otherwise, and the planner never reads it outside
      ## that case.

  MainlineSyncDecision* = object
    name*: string
    path*: string
    syncCase*: MainlineSyncCase
    action*: MainlineSyncAction
    branch*: string          ## The branch being reconciled.
    mainlineBranch*: string  ## What it is being reconciled WITH.
    message*: string
    refusalReason*: string

proc mainlineSyncCaseTag*(c: MainlineSyncCase): string =
  ## Stable snake_case identifiers for the JSON report, matching the names
  ## CLI/sync.md §"Refusal cases" uses verbatim.
  case c
  of mscUpToDate: "up_to_date"
  of mscFastForwardable: "fast_forwarded"
  of mscIntegrable: "integrated"
  of mscDiverged: "diverged"
  of mscConflict: "conflict"
  of mscDirty: "dirty"
  of mscDetachedHead: "detached_head"
  of mscNoMainlineBranch: "no_mainline_branch"
  of mscNoMainlineRef: "no_mainline_ref"
  of mscMissingCheckout: "missing_checkout"

proc mainlineSyncActionTag*(a: MainlineSyncAction): string =
  case a
  of msaNone: "none"
  of msaFastForward: "fast_forward"
  of msaRebase: "rebase"
  of msaMerge: "merge"

proc classifyMainlineSync*(resolved: ResolvedRepo;
                           obs: MainlineSyncObservation;
                           flavor: MainlineSyncFlavor): MainlineSyncDecision =
  ## The whole `--mainline` decision table, in one place and in priority order.
  result.name = resolved.name
  result.path = resolved.path
  result.branch = obs.currentBranch
  result.mainlineBranch = obs.mainlineBranch
  result.action = msaNone

  if not obs.exists:
    result.syncCase = mscMissingCheckout
    result.refusalReason = "no checkout at '" & resolved.path &
      "' — run `repro sync` or `repro workspace pull` first"
    result.message = result.refusalReason
    return

  # The manifest is this mode's input, so an incomplete fragment is named
  # rather than skipped — the same rule `switch --mainline` follows.
  if obs.mainlineBranch.len == 0:
    result.syncCase = mscNoMainlineBranch
    result.refusalReason = "repo '" & resolved.path &
      "' declares no `branch` in its manifest fragment" &
      (if resolved.fragmentPath.len > 0: " (" & resolved.fragmentPath & ")"
       else: "") & " — `--mainline` reconciles toward that field"
    result.message = result.refusalReason
    return

  if obs.currentBranch.len == 0:
    result.syncCase = mscDetachedHead
    result.refusalReason = "repo '" & resolved.path &
      "' is in detached HEAD; there is no branch to reconcile with '" &
      obs.mainlineBranch & "'"
    result.message = result.refusalReason
    return

  if obs.mainlineTip.len == 0:
    result.syncCase = mscNoMainlineRef
    result.refusalReason = "no remote-tracking branch for mainline '" &
      obs.mainlineBranch & "' in repo '" & resolved.path &
      "' after fetching — correct the fragment's `branch`, or restore that " &
      "branch on the remote"
    result.message = result.refusalReason
    return

  # Already carries trunk: identical, or the branch is strictly ahead. Both are
  # "nothing to integrate" — being ahead of trunk is the normal state of a
  # feature branch whose trunk has not moved, not something to act on.
  if obs.mainlineInHead:
    result.syncCase = mscUpToDate
    result.message = "'" & obs.currentBranch & "' already contains '" &
      obs.mainlineBranch & "'"
    return

  # No local commits of its own and trunk moved: a fast-forward, which needs no
  # decision and cannot rewrite anything.
  if obs.headInMainline:
    result.syncCase = mscFastForwardable
    result.action = msaFastForward
    result.message = "fast-forward '" & obs.currentBranch & "' to '" &
      obs.mainlineBranch & "'"
    return

  # Genuinely diverged from here on: both sides moved.
  if flavor == msfFastForwardOnly:
    result.syncCase = mscDiverged
    result.refusalReason = "'" & obs.currentBranch & "' and '" &
      obs.mainlineBranch & "' have both advanced in repo '" & resolved.path &
      "' — integrating is a judgment call. Re-run with --rebase to replay " &
      "your commits onto '" & obs.mainlineBranch & "', or --merge to record " &
      "a merge (scope it with --only=" & resolved.name & " if the answer " &
      "differs per repo)."
    result.message = result.refusalReason
    return

  # A flavor was chosen. Both `rebase` and `merge` require a clean tree, and a
  # conflict prediction made against a dirty one would not describe what the
  # operator would actually get.
  if not obs.isClean:
    result.syncCase = mscDirty
    result.refusalReason = "repo '" & resolved.path &
      "' has uncommitted changes; commit or stash them before integrating '" &
      obs.mainlineBranch & "' into '" & obs.currentBranch & "'"
    result.message = result.refusalReason
    return

  if obs.integrationConflicts:
    result.syncCase = mscConflict
    result.refusalReason = "integrating '" & obs.mainlineBranch & "' into '" &
      obs.currentBranch & "' in repo '" & resolved.path &
      "' would conflict; the repo is UNTOUCHED. Resolve it there (git -C " &
      resolved.path & " " &
      (if flavor == msfRebase: "rebase" else: "merge") & " " &
      obs.mainlineBranch & "), then re-run."
    result.message = result.refusalReason
    return

  result.syncCase = mscIntegrable
  result.action = if flavor == msfRebase: msaRebase else: msaMerge
  result.message =
    (if flavor == msfRebase: "rebase '" else: "merge '") &
    obs.currentBranch & "' onto '" & obs.mainlineBranch & "'"

proc planMainlineSync*(resolved: openArray[ResolvedRepo];
                       observations: openArray[MainlineSyncObservation];
                       flavor: MainlineSyncFlavor):
                      seq[MainlineSyncDecision] =
  ## One decision per resolved repo, in declaration order.
  if resolved.len != observations.len:
    raise newException(ValueError,
      "planMainlineSync requires one observation per resolved repo (got " &
        $resolved.len & " repos and " & $observations.len & " observations)")
  for i, repo in resolved:
    result.add(classifyMainlineSync(repo, observations[i], flavor))
