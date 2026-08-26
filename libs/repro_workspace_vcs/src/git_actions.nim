## Workspace VCS — git action constructors and executor (M2).
##
## This module exposes the primitive VCS operations from the
## ``Workspace-Management`` milestones as typed build actions the
## engine schedules under the new ``bakWorkspaceVcs`` kind:
##
##   - ``gitCloneAction`` — clone a remote into a target path; writes a
##     small ``clone-receipt`` file as the cacheable output.
##   - ``gitFetchAction`` — fetch from a named remote in an existing
##     working tree; writes a ``fetch-receipt`` capturing the post-fetch
##     remote-tracking HEADs.
##   - ``gitSwitchAction`` — ``git switch`` a branch in an existing
##     working tree, refusing on a dirty tree with the structured
##     reason ``"dirty"`` (the M2 contract). Writes a ``switch-receipt``.
##
## The mutating actions are cacheable. The unit of caching is the
## **receipt** (a small canonical text file) rather than the git
## working tree itself: caching the receipt lets the engine compute
## determinism without trying to content-address every loose object
## under ``.git/`` (per M2 design rule 1).
##
## The query operations (``head-sha``, ``is-clean``, ``is-published``)
## are observation-only and are surfaced as a separate proc shape that
## returns a structured ``GitQueryResult`` directly — they are NOT
## expressible as cacheable actions because their output is a property
## of the working tree at the moment of the query (per M2 design rule
## 3).
##
## Every cacheable action constructor accepts a ``GitToolIdentity`` and
## folds its ``digest`` into the action's ``weakFingerprint`` so two
## workspaces resolving to different ``git`` binaries are NOT confused
## by the action cache (per M2 design rule 2).
##
## The module installs its executor for ``bakWorkspaceVcs`` at module
## init time via ``registerWorkspaceVcsExecutor``. Tests that want to
## bind the executor to a fresh ``GitToolIdentity`` for hermetic
## fixtures can call ``installGitVcsExecutor(identity)`` explicitly.

import std/[os, osproc, strutils]

import repro_build_engine
import repro_core/codec
import repro_hash

import git_tool

export GitToolIdentity, EGitToolUnresolved, ensureGitToolResolvable,
  resolveGitTool, digestHex, ToolProvisioningMode

const
  WorkspaceVcsKind* = "git"
    ## Stable tag stored in receipts so future M3 (hg) artifacts cannot
    ## be confused with M2 (git) artifacts at restore time.
  CloneReceiptHeader* = "reprobuild.workspace-vcs.clone-receipt.v1"
  FetchReceiptHeader* = "reprobuild.workspace-vcs.fetch-receipt.v1"
  SwitchReceiptHeader* = "reprobuild.workspace-vcs.switch-receipt.v1"
  BranchCreateReceiptHeader* =
    "reprobuild.workspace-vcs.branch-create-receipt.v1"
  MergeFfReceiptHeader* =
    "reprobuild.workspace-vcs.merge-ff-receipt.v1"
  ForceResetReceiptHeader* =
    "reprobuild.workspace-vcs.force-reset-receipt.v1"
  ForkBranchReceiptHeader* =
    "reprobuild.workspace-vcs.fork-branch-receipt.v1"
  RefreshBareReceiptHeader* =
    "reprobuild.workspace-vcs.refresh-bare-receipt.v1"
  ForcePushRebaseReceiptHeader* =
    "reprobuild.workspace-vcs.force-push-rebase-receipt.v1"

type
  GitVcsOp* = enum
    gvoClone
    gvoFetch
    gvoSwitch
    gvoBranchCreate
    gvoMergeFf
    gvoForceReset
    gvoForcePushRebase
    gvoForkBranch
    gvoRefreshBare

  GitVcsPayload* = object
    ## Compact per-action payload encoded into ``builtinText`` so the
    ## executor can recover the operation parameters from a
    ## ``BuildAction`` alone. The encoding is a small key=value line
    ## list; we deliberately avoid JSON to keep the executor's parser
    ## tiny and side-effect free.
    op*: GitVcsOp
    remoteUrl*: string
    remoteName*: string
    branchName*: string
    revision*: string
    repoPath*: string
    receiptPath*: string
    identityDigestHex*: string
    identityVersion*: string
    binaryPath*: string
    referencePath*: string
      ## RA-5 — when non-empty (clone only), the shared bare clone to
      ## pass as ``git clone --reference``. The clone keeps
      ## ``objects/info/alternates`` pointing at the shared bare's
      ## ``objects/`` dir (we deliberately do NOT ``--dissociate``), so a
      ## later fetch transfers only objects not already in the shared
      ## pool. This is a pure acceleration field: it is intentionally
      ## EXCLUDED from the clone fingerprint so a cold-cache run (no
      ## reference) and a warm-cache run (reference present) share the
      ## same receipt and produce a byte-identical resolved tree
      ## (transparency).
    cloneFilter*: string
      ## RA-14 — partial-clone filter (``--filter=<spec>``), e.g.
      ## ``blob:none`` (blobless) or ``tree:0`` (treeless). When
      ## non-empty the clone is created as a promisor/partial clone:
      ## history is fetched but blobs (or trees) are lazily fetched on
      ## demand at checkout. The *checked-out* tree at the pinned
      ## revision is byte-identical to a full clone — only the on-disk
      ## ``.git`` object population differs — so this is an acceleration
      ## knob, EXCLUDED from the fingerprint (like ``referencePath``).
    depth*: int
      ## RA-14 — shallow-clone depth (``--depth <n>``). ``0`` means "no
      ## ``--depth``" (full history). A positive value truncates history
      ## to the last ``n`` commits of the pinned branch; a repo later
      ## promoted to develop-mode is deepened on demand (``git fetch
      ## --unshallow``). The checked-out tree at the tip is identical to
      ## a full clone, so this is also EXCLUDED from the fingerprint.
    singleBranch*: bool
      ## RA-14 — narrow fetch (``--single-branch``): clone/fetch only the
      ## pinned revision's branch's remote-tracking ref rather than every
      ## remote head (the ``repo sync -c`` equivalent). EXCLUDED from the
      ## fingerprint: the resolved tree at the pin is unchanged; only the
      ## set of remote-tracking refs differs.
    baseSha*: string

  GitQueryKind* = enum
    gqkHeadSha
    gqkIsClean
    gqkIsPublished
    gqkExtendedStatus

  GitQueryAction* = object
    ## Observation-only descriptor for the read-only query operations
    ## (head-sha, is-clean, is-published). NOT a BuildAction: these
    ## queries do NOT participate in the action cache (M2 design rule
    ## 3) and call sites consume the ``GitQueryResult`` directly.
    kind*: GitQueryKind
    repoPath*: string
    remoteName*: string
    trunkBranch*: string
    queryStashes*: bool
    queryFiles*: bool
    queryAheadBehind*: bool
    queryUnmerged*: bool
    queryFileDetails*: bool

  GitQueryStatus* = enum
    gqsOk
    gqsFailed

  FileStatusEntry* = object
    ## One changed path from ``git status --porcelain`` (v1). ``code`` is
    ## the raw two-column ``XY`` status (index column X, worktree column
    ## Y) — e.g. ``"M "`` (staged modification), ``" M"`` (unstaged),
    ## ``"MM"`` (both), ``"A "`` (added), ``"??"`` (untracked), ``"UU"``
    ## (conflict). ``path`` is the pathspec (for renames/copies the raw
    ## ``ORIG -> DEST`` form is preserved). This is the per-file detail
    ## behind the coarse ``modifiedCount`` / ``untrackedCount`` tallies.
    code*: string
    path*: string

  GitQueryResult* = object
    status*: GitQueryStatus
    headSha*: string
    isClean*: bool
    isPublished*: bool
    diagnostic*: string
    stashCount*: int
    aheadCount*: int
    behindCount*: int
    untrackedCount*: int
    modifiedCount*: int
    unmergedBranches*: seq[string]
    fileDetails*: seq[FileStatusEntry]


const PayloadVersion* = "reprobuild.workspace-vcs.payload.v1"
  ## First-line magic of a git-flavored payload encoded into
  ## ``builtinText``. The multiplexed executor (see
  ## ``executeWorkspaceVcsAction`` below) consults the first line of
  ## the encoded payload to discriminate git from hg actions: anything
  ## that starts with ``PayloadVersion`` is dispatched into the git
  ## implementations in this module, anything else is forwarded to the
  ## hg sub-executor registered by ``hg_actions``. The constant is
  ## exported (rather than module-private) only so ``hg_actions`` can
  ## use a parallel magic without colliding by accident.

proc opTag(op: GitVcsOp): string =
  case op
  of gvoClone: "clone"
  of gvoFetch: "fetch"
  of gvoSwitch: "switch"
  of gvoBranchCreate: "branch-create"
  of gvoMergeFf: "merge-ff"
  of gvoForceReset: "force-reset"
  of gvoForcePushRebase: "force-push-rebase"
  of gvoForkBranch: "fork-branch"
  of gvoRefreshBare: "refresh-bare"

proc parseOpTag(tag: string): GitVcsOp =
  case tag
  of "clone": gvoClone
  of "fetch": gvoFetch
  of "switch": gvoSwitch
  of "branch-create": gvoBranchCreate
  of "merge-ff": gvoMergeFf
  of "force-reset": gvoForceReset
  of "force-push-rebase": gvoForcePushRebase
  of "fork-branch": gvoForkBranch
  of "refresh-bare": gvoRefreshBare
  else:
    raise newException(ValueError,
      "unknown workspace-vcs operation tag: " & tag)

proc encodePayload(payload: GitVcsPayload): string =
  ## Encode the payload as a small key=value line list. The encoder
  ## escapes ``\`` and newline so values with embedded newlines (a
  ## malformed remote URL, say) cannot inject phantom fields.
  proc esc(value: string): string =
    result = newStringOfCap(value.len)
    for ch in value:
      case ch
      of '\\': result.add("\\\\")
      of '\n': result.add("\\n")
      else: result.add(ch)

  result = PayloadVersion & "\n"
  result.add("op=" & opTag(payload.op) & "\n")
  result.add("remote-url=" & esc(payload.remoteUrl) & "\n")
  result.add("remote-name=" & esc(payload.remoteName) & "\n")
  result.add("branch=" & esc(payload.branchName) & "\n")
  result.add("revision=" & esc(payload.revision) & "\n")
  result.add("repo-path=" & esc(payload.repoPath) & "\n")
  result.add("receipt-path=" & esc(payload.receiptPath) & "\n")
  result.add("identity-digest=" & payload.identityDigestHex & "\n")
  result.add("identity-version=" & esc(payload.identityVersion) & "\n")
  result.add("binary-path=" & esc(payload.binaryPath) & "\n")
  result.add("reference-path=" & esc(payload.referencePath) & "\n")
  result.add("clone-filter=" & esc(payload.cloneFilter) & "\n")
  result.add("depth=" & $payload.depth & "\n")
  result.add("single-branch=" & (if payload.singleBranch: "1" else: "0") & "\n")
  result.add("base-sha=" & esc(payload.baseSha) & "\n")

proc decodePayload(text: string): GitVcsPayload =
  proc unesc(value: string): string =
    result = newStringOfCap(value.len)
    var i = 0
    while i < value.len:
      if value[i] == '\\' and i + 1 < value.len:
        case value[i + 1]
        of '\\': result.add('\\')
        of 'n': result.add('\n')
        else: result.add(value[i + 1])
        i += 2
      else:
        result.add(value[i])
        i += 1

  let lines = text.splitLines()
  if lines.len == 0 or lines[0] != PayloadVersion:
    raise newException(ValueError,
      "workspace-vcs payload missing magic header (expected " &
        PayloadVersion & ")")
  for line in lines[1 .. ^1]:
    if line.len == 0:
      continue
    let eq = line.find('=')
    if eq < 0:
      raise newException(ValueError,
        "workspace-vcs payload line missing '=': " & line)
    let key = line[0 ..< eq]
    let value = unesc(line[eq + 1 .. ^1])
    case key
    of "op": result.op = parseOpTag(value)
    of "remote-url": result.remoteUrl = value
    of "remote-name": result.remoteName = value
    of "branch": result.branchName = value
    of "revision": result.revision = value
    of "repo-path": result.repoPath = value
    of "receipt-path": result.receiptPath = value
    of "identity-digest": result.identityDigestHex = value
    of "identity-version": result.identityVersion = value
    of "binary-path": result.binaryPath = value
    of "reference-path": result.referencePath = value
    of "clone-filter": result.cloneFilter = value
    of "depth":
      # A malformed/empty depth decodes to 0 ("no --depth") rather than
      # raising: the field is a pure accelerator and a missing value must
      # never break decode of an otherwise valid payload.
      try: result.depth = parseInt(value.strip())
      except ValueError: result.depth = 0
    of "single-branch": result.singleBranch = value.strip() == "1"
    of "base-sha": result.baseSha = value
    else:
      # Forward-compatible: ignore unknown keys so a payload written
      # by a newer M2.x build still decodes.
      discard

proc fingerprintPayload(payload: GitVcsPayload): seq[byte] =
  ## Build the fingerprint payload that will be hashed under
  ## ``hdActionFingerprint`` to produce the action's weak fingerprint.
  ## We pack a stable magic + every fingerprint-bearing field so two
  ## clones with the same logical parameters but different temp roots
  ## still produce the same digest (the local path is intentionally
  ## omitted from the clone fingerprint — see ``actionFingerprint``).
  result = @[]
  result.writeString("reprobuild.workspace-vcs.fingerprint.v1")
  result.writeString(WorkspaceVcsKind)
  result.writeString(opTag(payload.op))
  result.writeString(payload.identityDigestHex)
  result.writeString(payload.remoteUrl)
  result.writeString(payload.remoteName)
  result.writeString(payload.branchName)
  result.writeString(payload.revision)
  # RA-5 ``referencePath`` and RA-14 ``cloneFilter`` / ``depth`` /
  # ``singleBranch`` are DELIBERATELY NOT folded in here. They are pure
  # network/disk acceleration knobs: a blobless/shallow/single-branch
  # clone and a full clone of the same (remote, revision, identity)
  # resolve to a byte-identical working tree at the pinned revision, so
  # they must share one receipt / cache entry (transparency).
  # ``repoPath`` participates in fetch/switch fingerprints (those are
  # working-tree-local operations) but NOT in clone (M2 design rule 1:
  # the clone receipt for the same (remote, revision, identity) must
  # be a cache hit across two parallel temp roots).
  case payload.op
  of gvoClone:
    discard
  of gvoFetch, gvoSwitch, gvoBranchCreate, gvoMergeFf, gvoForceReset,
      gvoForcePushRebase, gvoForkBranch, gvoRefreshBare:
    result.writeString(payload.repoPath)
    if payload.op == gvoForcePushRebase:
      result.writeString(payload.baseSha)

proc actionFingerprint*(payload: GitVcsPayload): ContentDigest =
  blake3DomainDigest(fingerprintPayload(payload), hdActionFingerprint)

proc payloadFromAction*(action: BuildAction): GitVcsPayload =
  if action.kind != bakWorkspaceVcs:
    raise newException(ValueError,
      "payloadFromAction expects a bakWorkspaceVcs action: got " &
        $action.kind)
  decodePayload(action.builtinText)

proc receiptOutputPath*(action: BuildAction): string =
  ## The receipt path is recorded both in the payload (for the
  ## executor) and as the action's declared output (for the cache).
  ## The two must match.
  if action.outputs.len != 1:
    raise newException(ValueError,
      "bakWorkspaceVcs action must declare exactly one output (the receipt): " &
        action.id)
  action.outputs[0]

proc absoluteRepoPath(payload: GitVcsPayload; cwd: string): string =
  ## Resolve the payload's ``repoPath`` against the action's cwd so a
  ## relative path is rooted in the action's working directory, not
  ## the process cwd. Matches how the engine's other built-in actions
  ## interpret relative output paths.
  if payload.repoPath.isAbsolute:
    payload.repoPath
  elif cwd.len > 0:
    cwd / payload.repoPath
  else:
    payload.repoPath

type
  Containment = enum
    ## Where a computed target sits relative to the workspace root. The
    ## outcomes are kept apart because the CALLERS answer them differently and
    ## owe different remedies — collapsing them into one boolean is how the
    ## first shape of this guard produced
    ## `target 'X' is not beneath the workspace root 'X'`: the same path
    ## twice, joined by a phrase that is true but unreadable, with no remedy.
    ## It is also how that shape refused a SIBLING, which is the develop
    ## plane's documented default placement.
    cmBeneath              ## Strictly inside. The repo's own tree.
    cmIsWorkspaceRoot      ## The target IS the workspace root itself.
    cmContainsWorkspaceRoot  ## The target is an ANCESTOR of the workspace.
    cmDisjoint             ## Outside, and not an ancestor — a sibling.
    cmUnresolvable         ## No workspace root, or a path that will not
                           ## resolve.

proc containmentInWorkspaceRoot(target, cwd, what: string):
    tuple[verdict: Containment; root, victim, fact: string] =
  ## Locate `target` relative to the workspace root (`cwd`) and state the
  ## finding as a FACT — offender named, no remedy. The remedy belongs to the
  ## caller, because "what to do instead" differs per executor and a shared
  ## one would be wrong at every site (RA-28 /
  ## Interactive-UX-And-Progress.md Principle 2 requires both halves, and a
  ## generic remedy is a missing one).
  ##
  ## One definition of the QUESTION, asked by every executor in this file that
  ## does something irreversible to the directory it computed. Two
  ## independently-written copies of "is this contained?" is how one of them
  ## ends up narrower than the other, and the narrower one is always the one
  ## in front of the destructive call.
  ##
  ## Why `.` in particular reaches here: it is how a workspace declares its
  ## ROOT repo, so `declaredCheckoutPathRejection` admits it at the schema
  ## boundary and a payload carrying `repoPath = "."` is legitimate all the
  ## way down. Nothing upstream refuses it. `absoluteRepoPath` then turns it
  ## into the workspace root, and every caller of this proc is a place where
  ## acting on that blindly would be catastrophic.
  ##
  ## WHAT THIS PROC DOES NOT PROVE — two OPEN residuals, both written up in
  ## full at `repro_workspace_manifests/reader.nim`'s
  ## `lockedCheckoutPathRejection`, and both belonging to the same follow-up
  ## design pass rather than to a spot fix here:
  ##
  ##   * W5-R1 — `absolutePath(...).normalizedPath` is a LEXICAL fold. It does
  ##     not resolve reparse points, so a directory junction or symlink whose
  ##     target IS the workspace root reads as a disjoint sibling and is
  ##     cleared for deletion. Reproduced end to end on `repro develop --all
  ##     --reset`, exit 0, workspace destroyed.
  ##   * W5-R2 — the `==` and `startsWith` compares below are byte-wise, so
  ##     two spellings of the same directory that differ only in case compare
  ##     unequal on a case-insensitive filesystem. Latent: every caller today
  ##     derives `target` and `cwd` from the same bytes.
  if cwd.len == 0:
    return (cmUnresolvable, "", target,
      "there is no workspace root to locate the " & what & " target '" &
      target & "' within")
  let root = try: absolutePath(cwd).normalizedPath
             except CatchableError:
               return (cmUnresolvable, "", target,
                 "the workspace root '" & cwd & "' cannot be resolved")
  let victim = try: absolutePath(target).normalizedPath
               except CatchableError:
                 return (cmUnresolvable, root, target,
                   "the " & what & " target '" & target &
                   "' cannot be resolved")
  if victim == root:
    return (cmIsWorkspaceRoot, root, victim,
      "the " & what & " target IS the workspace root itself (" & root & ")")
  if victim.len > root.len and victim.startsWith(root & $DirSep):
    return (cmBeneath, root, victim, "")
  if root.len > victim.len and root.startsWith(victim & $DirSep):
    return (cmContainsWorkspaceRoot, root, victim,
      "the " & what & " target '" & victim & "' CONTAINS the workspace root " &
      "'" & root & "'")
  # Disjoint — a SIBLING of the workspace, and NOT an error here. This file's
  # executors serve two planes with different placement rules, and only one of
  # them forbids siblings:
  #
  #   * the MANIFEST/sync plane places every checkout beneath the workspace
  #     root, and `checkoutPathEscapeRejection` refuses `..` at the reader —
  #     so no manifest-derived payload can be disjoint in the first place, and
  #     a rule repeated here would be redundant;
  #   * the DEVELOP/lock plane's DEFAULT placement is the sibling topology one
  #     level above the workspace root (`../<name>`, CLI/develop.md §"Checkout
  #     Placement"), and `developAllTargetPath` honours a lock `path` that
  #     names one. Refusing siblings here breaks that outright: measured, a
  #     `repro develop --all` of a node locked at `path = "../sib"` failed
  #     with `force-reset-target-not-contained` and left the checkout at the
  #     branch tip.
  #
  # So the executors ask only what is catastrophic on BOTH planes — the root
  # itself and its ancestors — and the plane-specific rule is enforced where
  # the plane is known (the manifest reader, and
  # `developPlacementRejection`, which additionally bounds a develop
  # placement to the documented one-level-above scope).
  (cmDisjoint, root, victim, "")

proc removeCloneTargetSafely(target, cwd: string): tuple[ok: bool;
    diagnostic: string] =
  ## Delete a clone target, but only after proving it is one.
  ##
  ## Every `removeDir` in this file computes its argument from a
  ## manifest-supplied checkout path, and the cleanup paths run on the failure
  ## branches — a half-written clone, a checkout that died mid-filter — which
  ## are exactly the branches nobody exercises by hand. A checkout path of `.`
  ## makes that argument the workspace root and a `../..` makes it a directory
  ## the workspace lives inside, so the recovery step becomes the incident.
  ##
  ## For the ESCAPING shapes (absolute, empty, and `..` in a MANIFEST) the
  ## manifest reader refuses outright and this is the belt to that pair of
  ## braces. For `.` it
  ## is not the belt, it is the buckle: `.` is how a workspace declares its
  ## ROOT repo, so `declaredCheckoutPathRejection` admits it at the schema
  ## boundary and a payload carrying `repoPath = "."` reaches this file
  ## legitimately. Nothing upstream of here refuses it, so the containment
  ## proof below is the only thing between that payload and a recursive delete
  ## of the workspace root.
  ##
  ## It costs one string compare on a path that is about to be deleted
  ## recursively, and it holds for payloads that never came from a manifest at
  ## all — a lock-derived record, a synthesized action, a future caller.
  ## Refusing to delete is always survivable here: the worst outcome is a
  ## directory left behind and a diagnostic, against an unbounded recursive
  ## delete.
  let contained = containmentInWorkspaceRoot(target, cwd, "clone")
  if contained.verdict in {cmIsWorkspaceRoot, cmContainsWorkspaceRoot,
                           cmUnresolvable}:
    # RA-28: the fact, then the remedy. A clone target that is the workspace
    # (or holds it) means the DECLARATION is wrong, not the disk — nothing
    # here can be repaired by retrying, so the remedy points at the
    # declaration.
    # RA-28 wants the remedy to name a FILE, not a concept. This proc is
    # handed a computed directory and a workspace root and nothing else — no
    # repo name, no fragment path — so it cannot name the one offending
    # fragment. It can name the two files a checkout path is declared in, and
    # the key in each, which is the difference between "fix the declaration"
    # and knowing where to type. Which manifest directory is live is a
    # `dirExists` question (`manifestsRoot`'s rule, not importable here
    # without a dependency edge onto the TOML reader), so it is asked.
    let manifestDir =
      if dirExists(cwd / "repos"): cwd / "repos"
      else: cwd / ".repro" / "manifests" / "repos"
    return (false, "refusing to clean up the clone: " & contained.fact &
      ", so deleting it would destroy the workspace itself. The " &
      "half-finished clone is left in place. Remedy: fix the declared " &
      "checkout path for this repo — a manifest `path` (key `repo.path` in " &
      (manifestDir / "<repo>.toml") & "; `repro workspace repos list` prints " &
      "which repo declares which path) must name a directory beneath the " &
      "workspace root, and a lock `path` (key `deps[].path` in " &
      (cwd / "repro.lock") & ", regenerated by `repro lock refresh`) may " &
      "name a sibling but never the workspace or an ancestor of it — then " &
      "re-run `repro sync`.")
  let victim = contained.victim
  if not dirExists(victim):
    return (true, "")
  try:
    removeDir(victim)
    (true, "")
  except OSError as err:
    (false, err.msg)

proc gitVersionStringMatches(identityVersion: string;
                             observedVersion: string): bool =
  ## Loose equality: identity carries a canonical banner like
  ## ``git version 2.46.0``. The executor probes the binary again only
  ## as a sanity check; we accept any non-empty match.
  observedVersion.len > 0 and identityVersion.len > 0 and
    observedVersion == identityVersion

proc runGit(payload: GitVcsPayload; args: openArray[string];
            workingDir = ""): tuple[exitCode: int; output: string] =
  ## Invoke the identity-bound git binary with the requested arguments.
  ## We use ``execCmdEx`` to mirror M1's subprocess shape (no new
  ## third-party dependency, per the M2 hard constraint).
  var cmd = quoteShell(payload.binaryPath)
  for arg in args:
    cmd.add(" ")
    cmd.add(quoteShell(arg))
  let res = execCmdEx(cmd, workingDir = workingDir,
    env = scrubbedGitRepositoryEnv())
  (exitCode: res.exitCode, output: res.output)

proc trimmed(value: string): string = value.strip()

proc resolveHeadSha(payload: GitVcsPayload; repoPath: string): tuple[ok: bool; sha: string; diagnostic: string] =
  let res = runGit(payload, ["-C", repoPath, "rev-parse", "HEAD"])
  if res.exitCode != 0:
    return (ok: false, sha: "",
      diagnostic: "git rev-parse HEAD failed (" & $res.exitCode & "): " &
        res.output.trimmed)
  (ok: true, sha: res.output.trimmed, diagnostic: "")

proc workingTreeIsClean(payload: GitVcsPayload; repoPath: string): tuple[ok: bool; clean: bool; diagnostic: string] =
  let res = runGit(payload, ["-C", repoPath, "status", "--porcelain"])
  if res.exitCode != 0:
    return (ok: false, clean: false,
      diagnostic: "git status --porcelain failed (" & $res.exitCode & "): " &
        res.output.trimmed)
  (ok: true, clean: res.output.strip.len == 0, diagnostic: "")

proc remoteBranchContainsHead(payload: GitVcsPayload; repoPath, remote: string): tuple[ok: bool; published: bool; diagnostic: string] =
  ## Is HEAD contained in a remote-tracking branch?
  ##
  ## ``remote`` scopes the answer to one remote's refs (``<remote>/…``). Pass
  ## an EMPTY string to accept ANY remote-tracking branch — the right question
  ## when the caller has no configured expectation of which remote a repo
  ## should be published to, and the one the "not on any remote-tracking
  ## branch" diagnostic has always claimed to be asking.
  ##
  ## Scoping applies only when the named remote is actually configured in the
  ## worktree. A name that is not a real remote is a caller's guess, so it
  ## degrades to the any-remote answer rather than a confident falsehood; see
  ## the comment on the lookup below.
  ##
  ## The distinction is not academic: a repo checked out by the `repo` tool
  ## names its remote after the org (``metacraft-labs``), not ``origin``. A
  ## caller that hardcoded ``origin`` against such a worktree saw every commit
  ## as unpublished, including commits sitting on the remote's own default
  ## branch, and blocked pushes on that basis.
  let lookup = runGit(payload,
    ["-C", repoPath, "branch", "-r", "--contains", "HEAD"])
  if lookup.exitCode != 0:
    return (ok: false, published: false,
      diagnostic: "git branch -r --contains HEAD failed (" &
        $lookup.exitCode & "): " & lookup.output.trimmed)
  # A named remote that this checkout does not actually have is a GUESS, not a
  # constraint. `gitRemoteNameFor` falls back to "origin" whenever the manifest
  # entry carries no remote name, so callers routinely arrive here asking about
  # a remote that does not exist in the worktree — and in a `repo`-tool
  # workspace it never does, because the remotes are named after the org. Left
  # as-is that guess answers "unpublished" for commits sitting on the remote's
  # own default branch. Scoping is worth keeping when the caller names a remote
  # that IS configured; when it names one that is not, fall back to accepting
  # any remote-tracking branch rather than reporting a confident falsehood.
  var anyRemote = remote.len == 0
  if not anyRemote:
    let remotes = runGit(payload, ["-C", repoPath, "remote"])
    if remotes.exitCode == 0:
      var found = false
      for raw in remotes.output.splitLines:
        if raw.strip() == remote:
          found = true
          break
      if not found:
        anyRemote = true
  let needle = remote & "/"
  proc matches(candidate: string): bool =
    if anyRemote:
      # Any ``<remote>/<branch>`` line qualifies. Require the separator so a
      # malformed bare line cannot be mistaken for a tracking ref.
      candidate.len > 0 and '/' in candidate
    else:
      candidate.startsWith(needle)
  for raw in lookup.output.splitLines:
    let line = raw.strip()
    if line.len == 0:
      continue
    # Lines look like ``  origin/main`` or ``* origin/HEAD -> origin/main``.
    let normalized = line.replace("* ", "").strip()
    # ``HEAD -> origin/main`` form: prefer the target of the arrow, since the
    # left side is a symbolic name rather than a branch that contains HEAD.
    let arrowIndex = normalized.find(" -> ")
    if arrowIndex >= 0:
      let tail = normalized[arrowIndex + 4 .. ^1].strip()
      if matches(tail):
        return (ok: true, published: true, diagnostic: "")
      continue
    if matches(normalized):
      return (ok: true, published: true, diagnostic: "")
  (ok: true, published: false, diagnostic: "")

proc writeReceipt(receiptPath, content: string) =
  createDir(receiptPath.splitPath.head)
  writeFile(receiptPath, content)

proc renderCloneReceipt(payload: GitVcsPayload; headSha: string): string =
  result = CloneReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKind & "\n")
  result.add("operation\tclone\n")
  result.add("remote-url\t" & payload.remoteUrl & "\n")
  result.add("revision\t" & payload.revision & "\n")
  result.add("head-sha\t" & headSha & "\n")
  result.add("git-version\t" & payload.identityVersion & "\n")
  result.add("git-identity\t" & payload.identityDigestHex & "\n")

proc renderFetchReceipt(payload: GitVcsPayload; headSha, fetchOutput: string): string =
  result = FetchReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKind & "\n")
  result.add("operation\tfetch\n")
  result.add("remote-name\t" & payload.remoteName & "\n")
  result.add("repo-path\t" & payload.repoPath & "\n")
  result.add("head-sha\t" & headSha & "\n")
  result.add("git-version\t" & payload.identityVersion & "\n")
  result.add("git-identity\t" & payload.identityDigestHex & "\n")
  # ``execCmdEx`` on Windows preserves CRLF line endings from git's output.
  # Drop ``\r`` first so the resulting receipt has no embedded carriage
  # returns — otherwise the same logical fetch produces byte-different
  # receipts across Linux and Windows hosts.
  result.add("fetch-output\t" &
    fetchOutput.replace("\r", "").replace("\n", " ").strip() & "\n")

proc renderSwitchReceipt(payload: GitVcsPayload; headSha: string): string =
  result = SwitchReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKind & "\n")
  result.add("operation\tswitch\n")
  result.add("branch\t" & payload.branchName & "\n")
  result.add("repo-path\t" & payload.repoPath & "\n")
  result.add("head-sha\t" & headSha & "\n")
  result.add("git-version\t" & payload.identityVersion & "\n")
  result.add("git-identity\t" & payload.identityDigestHex & "\n")

proc renderBranchCreateReceipt(payload: GitVcsPayload;
                               headSha, outcome: string): string =
  ## ``outcome`` is one of ``created`` (the action actually invoked
  ## ``git branch <name> <sha>``) or ``already-at-head`` (a pre-existing
  ## branch by that name already pointed at HEAD — idempotent re-run).
  result = BranchCreateReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKind & "\n")
  result.add("operation\tbranch-create\n")
  result.add("branch\t" & payload.branchName & "\n")
  result.add("repo-path\t" & payload.repoPath & "\n")
  result.add("head-sha\t" & headSha & "\n")
  result.add("outcome\t" & outcome & "\n")
  result.add("git-version\t" & payload.identityVersion & "\n")
  result.add("git-identity\t" & payload.identityDigestHex & "\n")

proc renderForkBranchReceipt(payload: GitVcsPayload;
                             targetSha, outcome: string): string =
  ## ``outcome`` is one of ``created`` (the branch was created at the
  ## requested SHA and checked out), ``already-at-sha`` (an idempotent
  ## re-run — the branch already pointed at the SHA; the checkout is
  ## still asserted) or ``fetched-then-created`` (the SHA was absent and
  ## had to be fetched from the source checkout first).
  result = ForkBranchReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKind & "\n")
  result.add("operation\tfork-branch\n")
  result.add("branch\t" & payload.branchName & "\n")
  result.add("repo-path\t" & payload.repoPath & "\n")
  result.add("source\t" & payload.remoteUrl & "\n")
  result.add("target-sha\t" & targetSha & "\n")
  result.add("outcome\t" & outcome & "\n")
  result.add("git-version\t" & payload.identityVersion & "\n")
  result.add("git-identity\t" & payload.identityDigestHex & "\n")

proc renderMergeFfReceipt(payload: GitVcsPayload; headSha: string): string =
  result = MergeFfReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKind & "\n")
  result.add("operation\tmerge-ff\n")
  result.add("remote-name\t" & payload.remoteName & "\n")
  result.add("branch\t" & payload.branchName & "\n")
  result.add("repo-path\t" & payload.repoPath & "\n")
  result.add("head-sha\t" & headSha & "\n")
  result.add("git-version\t" & payload.identityVersion & "\n")
  result.add("git-identity\t" & payload.identityDigestHex & "\n")

proc renderForceResetReceipt(payload: GitVcsPayload; headSha: string): string =
  result = ForceResetReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKind & "\n")
  result.add("operation\tforce-reset\n")
  result.add("revision\t" & payload.revision & "\n")
  result.add("repo-path\t" & payload.repoPath & "\n")
  result.add("head-sha\t" & headSha & "\n")
  result.add("git-version\t" & payload.identityVersion & "\n")
  result.add("git-identity\t" & payload.identityDigestHex & "\n")

proc renderForcePushRebaseReceipt(payload: GitVcsPayload; headSha: string): string =
  result = ForcePushRebaseReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKind & "\n")
  result.add("operation\tforce-push-rebase\n")
  result.add("revision\t" & payload.revision & "\n")
  result.add("base-sha\t" & payload.baseSha & "\n")
  result.add("repo-path\t" & payload.repoPath & "\n")
  result.add("head-sha\t" & headSha & "\n")
  result.add("git-version\t" & payload.identityVersion & "\n")
  result.add("git-identity\t" & payload.identityDigestHex & "\n")

proc failed(reason, diagnostic: string): ActionResult =
  ## Structured failure result: ``reason`` is the contract field the
  ## test suite asserts on (e.g. ``"dirty"`` for the M2 switch-on-dirty
  ## test). ``stderr`` carries the human-facing message.
  ActionResult(
    status: asFailed,
    exitCode: 1,
    launched: true,
    runQuotaBackend: "workspace-vcs",
    reason: reason,
    stderr: diagnostic)

proc succeeded(): ActionResult =
  ActionResult(
    status: asSucceeded,
    exitCode: 0,
    launched: true,
    runQuotaBackend: "workspace-vcs")

proc isCommitSha(revision: string): bool =
  ## Whether ``revision`` is a full 40-hex commit id rather than a branch or
  ## tag name. This matters because ``git clone --branch`` accepts ONLY a
  ## branch or tag: handed a commit id it fails with "Remote branch <sha> not
  ## found in upstream origin", so a SHA-pinned repo fragment could never be
  ## cloned at all. A pinned commit is reached by cloning, fetching that
  ## object, and checking it out — the same three steps ``executeForkBranch``
  ## already uses to land on an arbitrary revision.
  revision.len == 40 and revision.allCharsInSet(HexDigits)

proc cloneBranchRef(revision: string): string =
  ## The spelling of ``revision`` that ``git clone --branch`` accepts.
  ##
  ## ``--branch`` takes a SHORT branch or tag name and resolves it against the
  ## remote itself; handed a fully-qualified ref it reports "Remote branch
  ## refs/tags/v1 not found in upstream origin" even though the tag is right
  ## there. Manifests legitimately pin the qualified form (it is the only way
  ## to say "the TAG v1", not "whichever ref happens to be named v1"), so the
  ## qualified spelling is normalized here rather than banned in the manifest
  ## schema.
  ##
  ## Only the two ref namespaces ``--branch`` can reach are stripped. Anything
  ## else (``refs/pull/…``, a bare name, a SHA) is passed through untouched so
  ## an unsupported pin still fails loudly at git rather than being silently
  ## rewritten into a different ref.
  for prefix in ["refs/heads/", "refs/tags/"]:
    if revision.startsWith(prefix):
      return revision[prefix.len .. ^1]
  revision

proc executeClone(payload: GitVcsPayload; cwd, receiptPath: string): ActionResult =
  let target = absoluteRepoPath(payload, cwd)
  let parent = target.splitPath.head
  if parent.len > 0:
    createDir(parent)
  if dirExists(target):
    if dirExists(target / ".git"):
      # A pre-existing *git* tree is a hard error: clone must be the act
      # of creating the working tree. The CLI-level "init-or-resync"
      # flow uses fetch/merge/force-reset, not clone, on an existing tree.
      return failed("clone-target-exists",
        "clone target already exists: " & target)
    # RA-16 resume correctness: a leftover directory with NO ``.git`` is a
    # half-cloned / interrupted-clone artifact (no receipt was written, so
    # the engine re-schedules this clone). Remove it so the re-run redoes
    # just this repo cleanly instead of being confused by the partial
    # state. We only remove a non-git directory — a real tree above — and only
    # one proven to sit beneath the workspace root.
    let cleaned = removeCloneTargetSafely(target, cwd)
    if not cleaned.ok:
      return failed("clone-partial-cleanup-failed",
        "could not remove half-cloned target " & target & ": " &
          cleaned.diagnostic)
  # RA-14 acceleration flags. These are network/disk knobs that do NOT
  # change the working tree at the pinned revision (see
  # ``fingerprintPayload``): ``--single-branch`` narrows the fetched
  # remote heads, ``--filter`` makes a partial (promisor) clone, and
  # ``--depth`` truncates history. They are appended to BOTH the
  # accelerated and the fallback plain-clone command lines.
  let pinnedCommit = isCommitSha(payload.revision)
  proc accelFlags(): seq[string] =
    result = @[]
    if payload.singleBranch:
      result.add("--single-branch")
    if payload.cloneFilter.len > 0:
      result.add("--filter=" & payload.cloneFilter)
    # ``--depth`` is dropped for a commit-id pin. The other accelerators only
    # narrow what is downloaded and the pinned commit is fetched explicitly
    # below, but a depth-truncated history cannot be guaranteed to contain an
    # arbitrary commit, and deepening it afterwards would download more than
    # the unshallowed clone would have.
    if payload.depth > 0 and not pinnedCommit:
      result.add("--depth")
      result.add($payload.depth)

  var args = @["clone"]
  # RA-5: accelerate via the shared bare clone. ``--reference <bare>``
  # leaves ``objects/info/alternates`` pointing at the shared pool (no
  # ``--dissociate``), so the clone reads objects already present in the
  # cache instead of re-downloading them. This is transparent: the
  # resolved tree at the pinned revision is byte-identical to a plain
  # clone. If the reference path turns out to be unusable, retry once as
  # a plain clone so the accelerator never breaks the clone itself.
  let useReference = payload.referencePath.len > 0 and
    (dirExists(payload.referencePath / "objects") or
     dirExists(payload.referencePath / ".git"))
  if useReference:
    args.add("--reference")
    args.add(payload.referencePath)
  for f in accelFlags():
    args.add(f)
  args.add(payload.remoteUrl)
  args.add(target)
  if payload.revision.len > 0 and not pinnedCommit:
    args.add("--branch")
    args.add(cloneBranchRef(payload.revision))
  var cloneRes = runGit(payload, args)
  if cloneRes.exitCode != 0 and useReference:
    # Best-effort fallback: drop the reference and clone standalone so a
    # broken/locked shared bare never breaks init. The RA-14 accelerators
    # are kept — they are independent of the shared bare.
    discard removeCloneTargetSafely(target, cwd)
    var plain = @["clone"]
    for f in accelFlags():
      plain.add(f)
    plain.add(payload.remoteUrl)
    plain.add(target)
    if payload.revision.len > 0 and not pinnedCommit:
      plain.add("--branch")
      plain.add(cloneBranchRef(payload.revision))
    cloneRes = runGit(payload, plain)
  if cloneRes.exitCode != 0:
    # A clone can fail in two shapes, and only one of them leaves nothing
    # behind. "Could not read from remote" fails before anything is created;
    # "Clone succeeded, but checkout failed" leaves a populated ``.git`` with a
    # half-written working tree. The second shape must not be left on disk: the
    # next sync classifies any directory with a ``.git`` as an existing
    # checkout and takes the UPDATE path, so the clone is never retried and the
    # repo stays half-checked-out indefinitely — the same trap the pinned-commit
    # branch below already guards against, reached by a different route.
    discard removeCloneTargetSafely(target, cwd)
    # git-lfs is the common cause of a checkout-stage failure, and its own
    # error names a filter rather than the repo, so the raw output reads as a
    # reprobuild bug. Say what actually happened and what can be done about it.
    let cloneOut = cloneRes.output.trimmed
    if cloneOut.contains("smudge filter lfs failed") or
        cloneOut.contains("Object does not exist on the server"):
      return failed("clone-lfs-objects-missing",
        "git clone of " & payload.remoteUrl & " checked out its tree but " &
        "git-lfs could not fetch the LFS content it points at (the server " &
        "answered 404 for at least one object), so the checkout was " &
        "discarded rather than left half-written.\n" &
        "  This is missing data on the LFS remote, not a bad revision — no " &
        "revision of this repo can be checked out until it is restored.\n" &
        "  To proceed WITHOUT the LFS content (pointer files in place of the " &
        "real ones), clone it once by hand with the smudge filter disabled:\n" &
        "    git -c filter.lfs.smudge= -c filter.lfs.process= clone " &
        payload.remoteUrl & " " & target & "\n" &
        "  git output: " & cloneOut)
    return failed("clone-failed",
      "git clone exited " & $cloneRes.exitCode & ": " & cloneOut)
  if pinnedCommit:
    # The clone landed on the remote's default branch; move to the pinned
    # commit. Fetch it explicitly first — it need not be a branch tip, and
    # with ``--single-branch`` or a partial clone it may not be present.
    #
    # If we cannot land on the pin, the checkout is REMOVED rather than left
    # behind. A tree that exists but sits on the default branch is worse than
    # no tree at all: the next sync classifies it as an existing checkout and
    # takes the update path, so it never retries the clone and the repo stays
    # silently at the wrong revision forever.
    proc discardPartial() =
      discard removeCloneTargetSafely(target, cwd)
    let wanted = payload.revision
    let present = runGit(payload,
      ["-C", target, "cat-file", "-e", wanted & "^{commit}"])
    if present.exitCode != 0:
      let fetched = runGit(payload,
        ["-C", target, "fetch", "--no-tags", "origin", wanted])
      if fetched.exitCode != 0:
        discardPartial()
        return failed("clone-revision-fetch-failed",
          "could not fetch pinned revision " & wanted & " from " &
            payload.remoteUrl & " (" & $fetched.exitCode & "): " &
            fetched.output.trimmed)
      let recheck = runGit(payload,
        ["-C", target, "cat-file", "-e", wanted & "^{commit}"])
      if recheck.exitCode != 0:
        discardPartial()
        return failed("clone-revision-missing",
          "pinned revision " & wanted & " is still absent after fetching " &
            "from " & payload.remoteUrl)
    let co = runGit(payload, ["-C", target, "checkout", "--detach", wanted])
    if co.exitCode != 0:
      discardPartial()
      return failed("clone-revision-checkout-failed",
        "git checkout --detach " & wanted & " exited " & $co.exitCode &
          ": " & co.output.trimmed)
  let headRes = resolveHeadSha(payload, target)
  if not headRes.ok:
    return failed("clone-head-probe-failed", headRes.diagnostic)
  let receipt = renderCloneReceipt(payload, headRes.sha)
  writeReceipt(receiptPath, receipt)
  succeeded()

proc executeFetch(payload: GitVcsPayload; cwd, receiptPath: string): ActionResult =
  let target = absoluteRepoPath(payload, cwd)
  if not dirExists(target / ".git"):
    return failed("fetch-target-missing",
      "fetch target is not a git working tree: " & target)
  var fetchArgs = @["-C", target, "fetch"]
  # RA-14 — carry the partial-clone filter and shallow depth onto the
  # fetch so a develop-mode "deepen on demand" (``--depth``/``--unshallow``)
  # or a widening of the promisor filter is expressible as the same
  # action. These never change the resolved tree, only how much is
  # downloaded.
  if payload.cloneFilter.len > 0:
    fetchArgs.add("--filter=" & payload.cloneFilter)
  if payload.depth > 0:
    fetchArgs.add("--depth")
    fetchArgs.add($payload.depth)
  fetchArgs.add(payload.remoteName)
  let res = runGit(payload, fetchArgs)
  if res.exitCode != 0:
    return failed("fetch-failed",
      "git fetch exited " & $res.exitCode & ": " & res.output.trimmed)
  let headRes = resolveHeadSha(payload, target)
  if not headRes.ok:
    return failed("fetch-head-probe-failed", headRes.diagnostic)
  let receipt = renderFetchReceipt(payload, headRes.sha, res.output)
  writeReceipt(receiptPath, receipt)
  succeeded()

proc executeSwitch(payload: GitVcsPayload; cwd, receiptPath: string): ActionResult =
  let target = absoluteRepoPath(payload, cwd)
  if not dirExists(target / ".git"):
    return failed("switch-target-missing",
      "switch target is not a git working tree: " & target)
  # Refuse on a dirty tree BEFORE invoking git switch — the contract
  # field is ``reason = "dirty"``, not a string match on git's output
  # (M2 design rule 4).
  let cleanRes = workingTreeIsClean(payload, target)
  if not cleanRes.ok:
    return failed("switch-status-probe-failed", cleanRes.diagnostic)
  if not cleanRes.clean:
    return failed("dirty",
      "git switch refused: working tree is dirty at " & target)
  let res = runGit(payload, ["-C", target, "switch", payload.branchName])
  if res.exitCode != 0:
    return failed("switch-failed",
      "git switch exited " & $res.exitCode & ": " & res.output.trimmed)
  let headRes = resolveHeadSha(payload, target)
  if not headRes.ok:
    return failed("switch-head-probe-failed", headRes.diagnostic)
  let receipt = renderSwitchReceipt(payload, headRes.sha)
  writeReceipt(receiptPath, receipt)
  succeeded()

proc resolveBranchSha(payload: GitVcsPayload; repoPath, branchName: string):
    tuple[exists: bool; sha: string; diagnostic: string] =
  ## Return whether ``branchName`` already exists locally and, if so,
  ## the SHA its tip points at. ``git rev-parse --verify`` returns
  ## a non-zero exit code when the ref does not exist — we treat that
  ## as the canonical "branch does not exist" signal rather than
  ## scraping the error text.
  let res = runGit(payload,
    ["-C", repoPath, "rev-parse", "--verify", "--quiet",
     "refs/heads/" & branchName])
  if res.exitCode == 0:
    let sha = res.output.trimmed
    if sha.len == 0:
      return (exists: false, sha: "",
        diagnostic: "git rev-parse --verify returned empty stdout for refs/heads/" &
          branchName)
    return (exists: true, sha: sha, diagnostic: "")
  # ``--quiet`` plus a missing ref → exit 1 with empty stdout. Any
  # other non-zero exit indicates a genuine probe failure.
  if res.output.strip().len == 0:
    return (exists: false, sha: "", diagnostic: "")
  (exists: false, sha: "",
    diagnostic: "git rev-parse --verify failed (" & $res.exitCode & "): " &
      res.output.trimmed)

proc executeBranchCreate(payload: GitVcsPayload;
                         cwd, receiptPath: string): ActionResult =
  ## Create a local branch pointing at the current HEAD without
  ## switching to it. The action is idempotent: a pre-existing branch
  ## by the same name pointing at HEAD short-circuits to
  ## ``outcome = already-at-head``. A pre-existing branch pointing
  ## elsewhere is a collision and fails with ``reason = "branch-collision"``
  ## so the M14 planner can refuse the workspace-wide create
  ## atomically.
  let target = absoluteRepoPath(payload, cwd)
  if not dirExists(target / ".git"):
    return failed("branch-create-target-missing",
      "branch-create target is not a git working tree: " & target)
  let headRes = resolveHeadSha(payload, target)
  if not headRes.ok:
    return failed("branch-create-head-probe-failed", headRes.diagnostic)
  let existing = resolveBranchSha(payload, target, payload.branchName)
  if existing.diagnostic.len > 0:
    return failed("branch-create-probe-failed", existing.diagnostic)
  var outcome = "created"
  if existing.exists:
    if existing.sha == headRes.sha:
      # Idempotent: branch already exists at HEAD. Record the receipt
      # and succeed without re-invoking ``git branch``.
      outcome = "already-at-head"
    else:
      return failed("branch-collision",
        "branch '" & payload.branchName & "' already exists at " &
          existing.sha & " (≠ HEAD " & headRes.sha & ") in " & target)
  else:
    let res = runGit(payload,
      ["-C", target, "branch", payload.branchName, headRes.sha])
    if res.exitCode != 0:
      return failed("branch-create-failed",
        "git branch exited " & $res.exitCode & ": " & res.output.trimmed)
  let receipt = renderBranchCreateReceipt(payload, headRes.sha, outcome)
  writeReceipt(receiptPath, receipt)
  succeeded()

proc executeForkBranch(payload: GitVcsPayload;
                       cwd, receiptPath: string): ActionResult =
  ## M27 — create ``branchName`` at an EXPLICIT ``revision`` (the source
  ## workspace's committed HEAD) and check it out, fetching that object
  ## from the source checkout (``remoteUrl``, a local path) when the
  ## freshly cloned repo does not carry it yet.
  ##
  ## This is the fork counterpart to ``gvoBranchCreate``: that one always
  ## branches from the target repo's OWN HEAD and never switches, which
  ## cannot express "branch at the SHA another checkout is sitting on" —
  ## including a commit that exists only locally and was never pushed.
  ##
  ## Idempotent, so a partially completed fork is finished by re-running
  ## the identical action: a branch already at the requested SHA is
  ## accepted and only the checkout is asserted. A branch of the same name
  ## at a DIFFERENT SHA is a collision and fails loudly rather than
  ## silently moving the operator's ref.
  let target = absoluteRepoPath(payload, cwd)
  if not dirExists(target / ".git"):
    return failed("fork-branch-target-missing",
      "fork-branch target is not a git working tree: " & target)
  let wanted = payload.revision.strip()
  if wanted.len == 0:
    return failed("fork-branch-no-revision",
      "fork-branch requires the source revision to branch at")

  # Ensure the object is present. A fresh clone of the shared remote has
  # every PUBLISHED commit, so this only fires for local-only work.
  var outcome = "created"
  let present = runGit(payload,
    ["-C", target, "cat-file", "-e", wanted & "^{commit}"])
  if present.exitCode != 0:
    if payload.remoteUrl.len == 0:
      return failed("fork-branch-source-missing",
        "commit " & wanted & " is absent from " & target &
          " and no source checkout was supplied to fetch it from")
    let fetched = runGit(payload,
      ["-C", target, "fetch", "--no-tags", payload.remoteUrl, wanted])
    if fetched.exitCode != 0:
      return failed("fork-branch-fetch-failed",
        "could not fetch " & wanted & " from " & payload.remoteUrl &
          " (" & $fetched.exitCode & "): " & fetched.output.trimmed)
    let recheck = runGit(payload,
      ["-C", target, "cat-file", "-e", wanted & "^{commit}"])
    if recheck.exitCode != 0:
      return failed("fork-branch-fetch-incomplete",
        "commit " & wanted & " still absent after fetching from " &
          payload.remoteUrl)
    outcome = "fetched-then-created"

  let existing = resolveBranchSha(payload, target, payload.branchName)
  if existing.diagnostic.len > 0:
    return failed("fork-branch-probe-failed", existing.diagnostic)
  if existing.exists:
    if existing.sha != wanted:
      return failed("branch-collision",
        "branch '" & payload.branchName & "' already exists at " &
          existing.sha & " (≠ requested " & wanted & ") in " & target)
    outcome = "already-at-sha"
    # Idempotent re-run: the branch is right, but HEAD may not be on it
    # yet (a run interrupted between create and checkout). Assert it.
    let current = runGit(payload,
      ["-C", target, "symbolic-ref", "--short", "-q", "HEAD"])
    if current.exitCode != 0 or current.output.trimmed != payload.branchName:
      let sw = runGit(payload, ["-C", target, "checkout", payload.branchName])
      if sw.exitCode != 0:
        return failed("fork-branch-checkout-failed",
          "git checkout " & payload.branchName & " exited " & $sw.exitCode &
            ": " & sw.output.trimmed)
  else:
    let created = runGit(payload,
      ["-C", target, "checkout", "-b", payload.branchName, wanted])
    if created.exitCode != 0:
      return failed("fork-branch-create-failed",
        "git checkout -b " & payload.branchName & " " & wanted & " exited " &
          $created.exitCode & ": " & created.output.trimmed)

  writeReceipt(receiptPath, renderForkBranchReceipt(payload, wanted, outcome))
  succeeded()

proc executeRefreshBare(payload: GitVcsPayload;
                        cwd, receiptPath: string): ActionResult =
  ## RA-27 — clone-if-missing / fetch-if-present the RA-5 shared bare for
  ## ``remoteUrl`` at ``repoPath``. Scheduling this as an engine action (rather
  ## than the serial in-line loop it replaces) is safe because each unique URL
  ## maps to its OWN bare directory: the race the serial loop guarded against is
  ## per-bare, and distinct bares share no state. The caller deduplicates by
  ## URL, so two actions never target the same directory.
  let bare = payload.repoPath
  var outcome = "fetched"
  if dirExists(bare / "objects") or dirExists(bare / ".git"):
    let res = runGit(payload,
      ["-C", bare, "fetch", "--all", "--prune", "--quiet"])
    if res.exitCode != 0:
      return failed("refresh-bare-fetch-failed",
        "git fetch in shared bare failed (" & $res.exitCode & "): " &
          res.output.trimmed)
  else:
    let parent = bare.splitPath.head
    if parent.len > 0:
      try: createDir(parent)
      except OSError as e:
        return failed("refresh-bare-parent-failed",
          "could not create cache parent " & parent & ": " & e.msg)
    let res = runGit(payload,
      ["clone", "--bare", "--quiet", payload.remoteUrl, bare])
    if res.exitCode != 0:
      # Leave no half-populated bare behind so the next attempt re-clones.
      if dirExists(bare):
        try: removeDir(bare)
        except OSError: discard
      return failed("refresh-bare-clone-failed",
        "git clone --bare into shared cache failed (" & $res.exitCode & "): " &
          res.output.trimmed)
    outcome = "cloned"
  var receipt = RefreshBareReceiptHeader & "\n"
  receipt.add("kind\t" & WorkspaceVcsKind & "\n")
  receipt.add("operation\trefresh-bare\n")
  receipt.add("remote-url\t" & payload.remoteUrl & "\n")
  receipt.add("bare-path\t" & bare & "\n")
  receipt.add("outcome\t" & outcome & "\n")
  receipt.add("git-version\t" & payload.identityVersion & "\n")
  writeReceipt(receiptPath, receipt)
  succeeded()

proc executeMergeFf(payload: GitVcsPayload;
                    cwd, receiptPath: string): ActionResult =
  ## RA-5c — fast-forward the working tree onto its tracked remote
  ## branch as an engine action (the checkout phase's counterpart to the
  ## network ``fetch``). The planner has already established that HEAD is
  ## an ancestor of ``<remote>/<branch>`` (so the merge is a strict
  ## fast-forward) and that the working tree is clean. ``merge --ff-only``
  ## is the safe primitive: it refuses (non-zero exit) rather than
  ## creating a merge commit if the relationship is not a pure
  ## fast-forward, so a planner/observer race degrades to a reported
  ## failure rather than a destructive merge. The remote-tracking ref is
  ## assumed current because the action depends on its sibling ``fetch``.
  let target = absoluteRepoPath(payload, cwd)
  if not dirExists(target / ".git"):
    return failed("merge-ff-target-missing",
      "merge-ff target is not a git working tree: " & target)
  let cleanRes = workingTreeIsClean(payload, target)
  if not cleanRes.ok:
    return failed("merge-ff-status-probe-failed", cleanRes.diagnostic)
  if not cleanRes.clean:
    # Defensive: the planner only emits a fast-forward for a clean tree,
    # but never merge into a dirty tree even if we are asked to.
    return failed("dirty",
      "git merge --ff-only refused: working tree is dirty at " & target)
  let ref0 = "refs/remotes/" & payload.remoteName & "/" & payload.branchName
  let res = runGit(payload,
    ["-C", target, "merge", "--ff-only", ref0])
  if res.exitCode != 0:
    return failed("merge-ff-failed",
      "git merge --ff-only exited " & $res.exitCode & ": " &
        res.output.trimmed)
  # After the fast-forward the superproject's submodule gitlinks may point at
  # new commits. Bring already-checked-out submodules in line so the
  # superproject does not end up dirty with a stale ``M <submodule>`` gitlink
  # (which would, e.g., block ``repro branch``). Only touches submodules that
  # are already initialized (no ``--init``), so it never materializes a checkout
  # the operator did not ask for; a no-op when there are no submodules. Best
  # effort — a submodule-update failure must NOT fail the fast-forward itself
  # (the superproject IS fast-forwarded), mirroring how ``git pull`` treats
  # submodule recursion.
  if fileExists(target / ".gitmodules"):
    discard runGit(payload,
      ["-C", target, "submodule", "update", "--recursive"])
  let headRes = resolveHeadSha(payload, target)
  if not headRes.ok:
    return failed("merge-ff-head-probe-failed", headRes.diagnostic)
  let receipt = renderMergeFfReceipt(payload, headRes.sha)
  writeReceipt(receiptPath, receipt)
  succeeded()

proc executeForceReset(payload: GitVcsPayload;
                       cwd, receiptPath: string): ActionResult =
  ## RA-16 ``--force-sync`` — OVERWRITE a divergent / dirty / locally
  ## mangled checkout so it matches the manifest-locked revision exactly.
  ## This is the explicit-opt-in destructive arm the normal sync planner
  ## never reaches: a normal sync report-only-SKIPS a divergent or dirty
  ## tree; only the force path resets it.
  ##
  ## The reset is deliberately thorough so the tree ends byte-identical to
  ## a fresh checkout at the locked SHA: ``git reset --hard <revision>``
  ## moves HEAD and the index, and ``git clean -ffdx`` removes any
  ## untracked / ignored leftovers (a half-applied merge, stray build
  ## output, a manually-dropped file). ``revision`` is the concrete locked
  ## SHA (or a ref) the caller resolved; it must already be present in the
  ## object store (the fetch phase / shared bare guarantees this for a
  ## divergent tree, since the locked commit is reachable).
  let target = absoluteRepoPath(payload, cwd)
  # `git clean -ffdx` is a recursive delete, and it is bounded by the repo's
  # tree — which is only a bound at all while that tree is the repo's OWN.
  # Given `repoPath = "."` the line above computes the WORKSPACE ROOT, and
  # then `clean -ffdx` removes every untracked and ignored entry under it:
  # `projects/`, `repos/`, `.repro/`, and — because a sibling checkout is
  # just an untracked directory from the root repo's point of view — EVERY
  # OTHER REPO'S WORKING TREE IN THE WORKSPACE. Measured, not argued: a
  # `repro sync --force-sync --force` against a workspace whose root repo is
  # declared at `.` deleted the workspace's manifests and a second repo's
  # entire checkout.
  #
  # `.` reaches here legitimately — it is how a workspace declares its root
  # repo, and `declaredCheckoutPathRejection` admits it at the schema
  # boundary on purpose — so the verdict below is the only thing in the way,
  # exactly as it is for `removeCloneTargetSafely` two hundred lines up.
  #
  # WHAT TO DO ABOUT IT IS NOT "REFUSE". The two halves of a force-reset are
  # not equally dangerous, and only one of them is out of bounds:
  #
  #   * `git reset --hard <sha>` is bounded by git's TRACKED set. On the
  #     workspace root that is the root repo's own files and nothing else —
  #     a sibling checkout, `.repro/` and the manifests are untracked from
  #     the root repo's point of view, so the reset cannot reach them. This
  #     half is exactly as safe on the root repo as on any other.
  #   * `git clean -ffdx` is bounded by the DIRECTORY, which on the root repo
  #     is the whole workspace. This half, and only this half, is the hazard.
  #
  # So the root repo gets the reset and not the clean, and the run says so.
  # An `-e <pattern>` exclusion list was considered and rejected: the sync
  # planner holds the declared checkout paths of the project being synced,
  # NOT of every project in the workspace, so an exclusion list built from it
  # would still delete a currently-disabled project's checkouts — a guard
  # that exists and does not hold, which is the failure mode this whole
  # change is about. Skipping the clean has no such edge: it deletes nothing.
  #
  # A target that CONTAINS the workspace root is different in kind and is
  # refused: unlike the root case there is no half of the operation that is in
  # bounds, since `reset --hard` would be reverting a repo the workspace lives
  # inside. A merely DISJOINT target — a sibling — is NOT refused: it is the
  # develop plane's documented default placement (see
  # `containmentInWorkspaceRoot`), and refusing it broke `repro develop --all`
  # for every node locked at `path = "../name"`.
  let contained = containmentInWorkspaceRoot(target, cwd, "force-reset")
  if contained.verdict in {cmContainsWorkspaceRoot, cmUnresolvable}:
    return failed("force-reset-target-not-contained",
      "refusing to force-reset: " & contained.fact &
      ", and `git reset --hard` + `git clean -ffdx` there would overwrite " &
      "and delete the workspace from the outside. Nothing was changed. " &
      "Remedy: fix the declared checkout path for this repo — it may name a " &
      "directory beneath the workspace root or a sibling of it, never an " &
      "ancestor — then re-run `repro sync --force-sync`.")
  let targetIsWorkspaceRoot = contained.verdict == cmIsWorkspaceRoot
  if not dirExists(target / ".git"):
    return failed("force-reset-target-missing",
      "force-reset target is not a git working tree: " & target)
  if payload.revision.len == 0:
    return failed("force-reset-no-revision",
      "force-reset requires a target revision to reset onto")
  let resetRes = runGit(payload,
    ["-C", target, "reset", "--hard", payload.revision])
  if resetRes.exitCode != 0:
    return failed("force-reset-failed",
      "git reset --hard " & payload.revision & " exited " &
        $resetRes.exitCode & ": " & resetRes.output.trimmed)
  # Remove untracked and ignored leftovers so the overwrite is complete —
  # unless the "repo's tree" is the whole workspace, in which case those
  # leftovers are the other repos. See the reasoning above the containment
  # verdict.
  var notice = ""
  if targetIsWorkspaceRoot:
    notice = "force-reset of the workspace root repo reset its TRACKED " &
      "files to " & payload.revision & " but did NOT run `git clean -ffdx`: " &
      "the target is the workspace root (" & contained.root & "), where " &
      "every sibling checkout, `.repro/` and the workspace manifests are " &
      "untracked, and the clean would have deleted all of them. Untracked " &
      "and ignored files were left in place. Remedy: list what the clean " &
      "would have taken with `git -C " & contained.root &
      " clean -ndx` and remove only what you mean to."
  else:
    let cleanRes = runGit(payload, ["-C", target, "clean", "-ffdx"])
    if cleanRes.exitCode != 0:
      return failed("force-reset-clean-failed",
        "git clean -ffdx exited " & $cleanRes.exitCode & ": " &
          cleanRes.output.trimmed)
  let headRes = resolveHeadSha(payload, target)
  if not headRes.ok:
    return failed("force-reset-head-probe-failed", headRes.diagnostic)
  let receipt = renderForceResetReceipt(payload, headRes.sha)
  writeReceipt(receiptPath, receipt)
  if notice.len > 0:
    # A SUCCESS that did less than the verb's name promises has to say so on
    # the row the operator reads, not only in a log. `reason` marks the row as
    # carrying a notice; `stderr` is the human-facing text, the same pairing
    # `failed` uses.
    var partial = succeeded()
    partial.reason = "force-reset-workspace-root-clean-skipped"
    partial.stderr = notice
    return partial
  succeeded()

proc executeForcePushRebase(payload: GitVcsPayload;
                            cwd, receiptPath: string): ActionResult =
  ## Cherry-pick locally authored commits since the force-pushed base Sha
  ## onto the new remote tip.
  let target = absoluteRepoPath(payload, cwd)
  if not dirExists(target / ".git"):
    return failed("force-push-rebase-target-missing",
      "force-push-rebase target is not a git working tree: " & target)
  if payload.baseSha.len == 0:
    return failed("force-push-rebase-no-base-sha",
      "force-push-rebase requires a force-pushed base SHA")
  
  let cleanRes = workingTreeIsClean(payload, target)
  if not cleanRes.ok:
    return failed("force-push-rebase-status-probe-failed", cleanRes.diagnostic)
  if not cleanRes.clean:
    return failed("dirty",
      "git force-push-rebase refused: working tree is dirty at " & target)

  # 1. Retrieve the list of commits in the range <baseSha>..HEAD in chronological order (oldest first)
  let listRes = runGit(payload,
    ["-C", target, "log", "--format=%H", "--reverse", payload.baseSha & "..HEAD"])
  if listRes.exitCode != 0:
    return failed("force-push-rebase-log-failed",
      "git log failed to find commits: " & listRes.output.trimmed)
  
  let commitsToCherryPick = listRes.output.strip().splitLines()

  # 2. Reset the branch to the remote tracking tip
  let rName = if payload.remoteName.len > 0: payload.remoteName else: "origin"
  let remoteRef = "refs/remotes/" & rName & "/" & payload.branchName
  let resetRes = runGit(payload,
    ["-C", target, "reset", "--hard", remoteRef])
  if resetRes.exitCode != 0:
    return failed("force-push-rebase-reset-failed",
      "git reset --hard " & remoteRef & " failed: " & resetRes.output.trimmed)

  # 3. Cherry-pick each of the local commits in order
  for rawCommit in commitsToCherryPick:
    let commit = rawCommit.strip()
    if commit.len == 0: continue
    let cpRes = runGit(payload, ["-C", target, "cherry-pick", commit])
    if cpRes.exitCode != 0:
      discard runGit(payload, ["-C", target, "cherry-pick", "--abort"])
      return failed("cherry-pick-failed",
        "git cherry-pick " & commit & " failed: " & cpRes.output.trimmed)

  let headRes = resolveHeadSha(payload, target)
  if not headRes.ok:
    return failed("force-push-rebase-head-probe-failed", headRes.diagnostic)
  let receipt = renderForcePushRebaseReceipt(payload, headRes.sha)
  writeReceipt(receiptPath, receipt)
  succeeded()

type
  WorkspaceVcsSubExecutor* = proc(action: BuildAction): ActionResult {.gcsafe.}
    ## Callback shape used by sibling VCS backends (currently
    ## ``hg_actions``) to plug a per-VCS executor into the single
    ## ``bakWorkspaceVcs`` dispatcher this module owns.
    ##
    ## The dispatcher peeks at the first line of ``action.builtinText``;
    ## if it matches ``PayloadVersion`` the action runs through git's
    ## ``executeClone`` / ``executeFetch`` / ``executeSwitch`` arms, and
    ## otherwise it is forwarded to whichever sub-executor was
    ## registered for that magic. The engine sees exactly one
    ## ``WorkspaceVcsExecutor`` (the multiplexer below), so the M2
    ## engine seam survives unchanged into M3.

# Process-global (NOT {.threadvar.}). The sub-executor is registered once
# at module-init time on the main thread by ``hg_actions`` and read from
# whichever build-engine worker thread happens to dispatch a hg-flavored
# ``bakWorkspaceVcs`` action. A threadvar would leave every worker thread
# with the default (nil) and silently fail every hg action with
# "no registered VCS sub-executor". The single-writer / many-reader access
# pattern is sound without explicit synchronisation: ``installGitVcsExecutor``
# only runs at module init, before the engine has spawned any workers,
# so the publication is naturally ordered with respect to every later
# read inside ``executeWorkspaceVcsAction``.
var hgSubExecutor: WorkspaceVcsSubExecutor
var hgSubMagic: string

proc registerHgSubExecutor*(magic: string; executor: WorkspaceVcsSubExecutor) =
  ## Install a sub-executor for hg actions. ``magic`` is the first line
  ## the dispatcher will match against (parallel to git's
  ## ``PayloadVersion``). Called by ``hg_actions`` at module-init time;
  ## tests can re-install after ``clearWorkspaceVcsExecutor`` /
  ## ``clearHgSubExecutor``.
  hgSubMagic = magic
  hgSubExecutor = executor

proc clearHgSubExecutor*() =
  hgSubMagic = ""
  hgSubExecutor = nil

proc currentHgSubExecutor(): tuple[executor: WorkspaceVcsSubExecutor;
                                   magic: string] {.gcsafe.} =
  ## Single-point gcsafe read of the module-global sub-executor. The
  ## ``cast(gcsafe)`` is sound because writes only happen at module-init
  ## time on the main thread (see the comment by the var declarations);
  ## the build engine's worker threads only ever read.
  {.cast(gcsafe).}:
    result = (executor: hgSubExecutor, magic: hgSubMagic)

proc payloadMagicLine(text: string): string =
  ## Cheap discriminator: return the first non-empty line of the
  ## encoded payload. We deliberately avoid running the full
  ## ``decodePayload`` parser here — git's parser raises on any line
  ## that is not in the git schema, which would mask a perfectly valid
  ## hg payload as a "decode error".
  let nl = text.find('\n')
  if nl < 0: text else: text[0 ..< nl]

proc executeWorkspaceVcsAction(action: BuildAction): ActionResult {.gcsafe.} =
  ## Single dispatcher that the engine sees as the registered
  ## ``WorkspaceVcsExecutor``. The dispatcher reads the magic at the
  ## head of the payload and routes to git's own per-op arms or to the
  ## hg sub-executor registered via ``registerHgSubExecutor``. M2's
  ## engine seam is unchanged; the multiplexing happens here, inside
  ## the VCS library, where both VCSes are visible.
  let magic = payloadMagicLine(action.builtinText)
  if magic != PayloadVersion:
    let sub = currentHgSubExecutor()
    if sub.executor.isNil or magic != sub.magic:
      return failed("payload-decode-failed",
        "bakWorkspaceVcs payload magic " & magic &
          " is not handled by any registered VCS sub-executor" &
          " (expected " & PayloadVersion &
          (if sub.magic.len > 0: " or " & sub.magic else: "") & ")")
    var subResult = sub.executor(action)
    subResult.id = action.id
    return subResult
  var payload: GitVcsPayload
  try:
    payload = payloadFromAction(action)
  except CatchableError as err:
    return failed("payload-decode-failed", err.msg)
  if action.outputs.len != 1:
    return failed("missing-receipt-output",
      "bakWorkspaceVcs action must declare exactly one output (the receipt)")
  let receiptRel = action.outputs[0]
  let receiptPath =
    if receiptRel.isAbsolute or action.cwd.len == 0: receiptRel
    else: action.cwd / receiptRel
  case payload.op
  of gvoClone: result = executeClone(payload, action.cwd, receiptPath)
  of gvoFetch: result = executeFetch(payload, action.cwd, receiptPath)
  of gvoSwitch: result = executeSwitch(payload, action.cwd, receiptPath)
  of gvoBranchCreate:
    result = executeBranchCreate(payload, action.cwd, receiptPath)
  of gvoMergeFf:
    result = executeMergeFf(payload, action.cwd, receiptPath)
  of gvoForceReset:
    result = executeForceReset(payload, action.cwd, receiptPath)
  of gvoForcePushRebase:
    result = executeForcePushRebase(payload, action.cwd, receiptPath)
  of gvoForkBranch:
    result = executeForkBranch(payload, action.cwd, receiptPath)
  of gvoRefreshBare:
    result = executeRefreshBare(payload, action.cwd, receiptPath)
  result.id = action.id
  # ``executeBuiltinAction`` wraps the returned ``ActionResult`` and
  # re-sets ``dependencyPolicyKind`` from the action's declared
  # dependency policy, so we deliberately leave that field at its
  # default zero value here.

proc installGitVcsExecutor*() =
  ## Explicit entry point so tests that need a fresh executor binding
  ## can re-install it (e.g. after ``clearWorkspaceVcsExecutor``).
  registerWorkspaceVcsExecutor(executeWorkspaceVcsAction)

# Install the executor at module init time so any caller that simply
# imports ``git_actions`` and constructs an action via the helpers
# below gets a working dispatch automatically.
installGitVcsExecutor()

proc buildPayload(identity: GitToolIdentity; op: GitVcsOp;
                  remoteUrl, remoteName, branchName, revision,
                  repoPath, receiptPath: string;
                  referencePath = "";
                  cloneFilter = ""; depth = 0; singleBranch = false;
                  baseSha = ""): GitVcsPayload =
  GitVcsPayload(
    op: op,
    remoteUrl: remoteUrl,
    remoteName: remoteName,
    branchName: branchName,
    revision: revision,
    repoPath: repoPath,
    receiptPath: receiptPath,
    identityDigestHex: identity.digestHex(),
    identityVersion: identity.version,
    binaryPath: identity.binaryPath,
    referencePath: referencePath,
    cloneFilter: cloneFilter,
    depth: depth,
    singleBranch: singleBranch,
    baseSha: baseSha)

proc gitCloneAction*(id: string; identity: GitToolIdentity;
                     remoteUrl, repoPath, receiptPath: string;
                     revision = ""; cwd = ""; deps: openArray[string] = [];
                     cacheable = true; referencePath = "";
                     cloneFilter = ""; depth = 0;
                     singleBranch = false): BuildAction =
  ## Construct a cacheable clone action. The receipt path is the
  ## action's declared output and the unit of caching (per M2 design
  ## rule 1). ``revision``, when non-empty, is passed as ``--branch``
  ## to ``git clone``.
  ##
  ## The action fingerprint folds the ``GitToolIdentity.digest`` so
  ## two workspaces resolving to different git binaries cannot share
  ## a cache entry (per M2 design rule 2).
  ##
  ## RA-5 — ``referencePath``, when set, names the shared bare clone to
  ## pass as ``git clone --reference`` so the clone reads objects from
  ## the shared pool instead of re-downloading them. It is deliberately
  ## OMITTED from the fingerprint (see ``fingerprintPayload``) so a
  ## cold-cache clone and a warm-cache clone share the same receipt and
  ## produce a byte-identical resolved tree (transparency).
  ##
  ## RA-14 — ``cloneFilter`` (``--filter=blob:none``/``tree:0``),
  ## ``depth`` (``--depth``), and ``singleBranch`` (``--single-branch``)
  ## are the network-economy accelerators. Like ``referencePath`` they
  ## are OMITTED from the fingerprint so a partial/shallow/narrow clone
  ## and a full clone of the same pin share one receipt and resolve to a
  ## byte-identical working tree.
  let payload = buildPayload(identity, gvoClone, remoteUrl, "", "",
    revision, repoPath, receiptPath, referencePath = referencePath,
    cloneFilter = cloneFilter, depth = depth, singleBranch = singleBranch)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    # Named-Lock-Files §7.2. A workspace VCS operation materialises a
    # CHECKOUT, and `Workspace-Manifests.md` §"Mode-agnostic" is explicit
    # that develop-vs-store-installed "is never recorded in the lock" — so
    # no solved package instance governs this edge. See
    # `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    text = encodePayload(payload))

proc gitFetchAction*(id: string; identity: GitToolIdentity;
                     remoteName, repoPath, receiptPath: string;
                     cwd = ""; deps: openArray[string] = [];
                     cacheable = true;
                     cloneFilter = ""; depth = 0): BuildAction =
  ## Construct a cacheable fetch action. The fingerprint includes the
  ## ``repoPath`` because a fetch is a working-tree-local operation:
  ## two workspaces with the same remote name but different working
  ## trees must NOT share a cache entry.
  ##
  ## RA-14 — ``cloneFilter``/``depth`` carry the partial/shallow knobs
  ## onto the fetch (``--filter``/``--depth``) for develop-mode
  ## deepen-on-demand. They are excluded from the fingerprint (they do
  ## not change the resolved tree).
  let payload = buildPayload(identity, gvoFetch, "", remoteName, "",
    "", repoPath, receiptPath, cloneFilter = cloneFilter, depth = depth)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    # Named-Lock-Files §7.2. A workspace VCS operation materialises a
    # CHECKOUT, and `Workspace-Manifests.md` §"Mode-agnostic" is explicit
    # that develop-vs-store-installed "is never recorded in the lock" — so
    # no solved package instance governs this edge. See
    # `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    text = encodePayload(payload))

proc gitSwitchAction*(id: string; identity: GitToolIdentity;
                      branchName, repoPath, receiptPath: string;
                      cwd = ""; deps: openArray[string] = [];
                      cacheable = false): BuildAction =
  ## Construct a switch action. The executor refuses on a dirty working
  ## tree and surfaces ``reason = "dirty"`` via the ``ActionResult`` (per
  ## M2 design rule 4).
  ##
  ## ``cacheable`` defaults to ``false`` (like ``gitMergeFfAction`` and
  ## ``gitForceResetAction``): ``git switch`` mutates a working tree whose
  ## precondition — the LIVE current HEAD — is observed at run time, not a
  ## deterministic function of the declared inputs (branch + repo). Caching
  ## its receipt is unsound: once a switch to branch ``B`` succeeded, a
  ## later switch to ``B`` from a DIFFERENT branch would be served as a
  ## cache hit and skip the actual ``git switch``, so ``repro switch``
  ## would report ``switched`` while HEAD never moved. ``git switch`` is
  ## idempotent (already-on-branch is a safe no-op), so always executing is
  ## both correct and cheap.
  let payload = buildPayload(identity, gvoSwitch, "", "", branchName,
    "", repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    # Named-Lock-Files §7.2. A workspace VCS operation materialises a
    # CHECKOUT, and `Workspace-Manifests.md` §"Mode-agnostic" is explicit
    # that develop-vs-store-installed "is never recorded in the lock" — so
    # no solved package instance governs this edge. See
    # `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    text = encodePayload(payload))

proc gitBranchCreate*(id: string; identity: GitToolIdentity;
                     branchName, repoPath, receiptPath: string;
                     cwd = ""; deps: openArray[string] = [];
                     cacheable = true): BuildAction =
  ## Construct a cacheable branch-create action used by M14
  ## (``repro branch <name>``). The executor invokes
  ## ``git branch <name> <HEAD-sha>`` in the named working tree —
  ## the branch is created from the current HEAD and the working tree
  ## is NOT switched to it (M15 ``repro switch`` is the switching
  ## form). Idempotent: a pre-existing branch by the same name at
  ## the same HEAD short-circuits to ``outcome = already-at-head``
  ## in the receipt; a branch by that name at a different SHA fails
  ## with ``reason = "branch-collision"``.
  let payload = buildPayload(identity, gvoBranchCreate, "", "", branchName,
    "", repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    # Named-Lock-Files §7.2. A workspace VCS operation materialises a
    # CHECKOUT, and `Workspace-Manifests.md` §"Mode-agnostic" is explicit
    # that develop-vs-store-installed "is never recorded in the lock" — so
    # no solved package instance governs this edge. See
    # `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    text = encodePayload(payload))

proc gitForkBranchAction*(id: string; identity: GitToolIdentity;
                          branchName, sourceRepoPath, targetSha,
                          repoPath, receiptPath: string;
                          cwd = ""; deps: openArray[string] = [];
                          cacheable = false): BuildAction =
  ## Construct the M27 fork-branch action used by
  ## ``repro branch <name> <path>``: create ``branchName`` at
  ## ``targetSha`` (the source workspace's committed HEAD for this repo)
  ## and check it out, fetching the commit from ``sourceRepoPath`` when
  ## the freshly cloned repo does not already carry it.
  ##
  ## ``cacheable`` defaults to ``false`` for the same reason as
  ## ``gitSwitchAction``: the action mutates a working tree whose
  ## precondition is the LIVE state of the target checkout, not a
  ## deterministic function of the declared inputs. The executor is
  ## idempotent, so always executing is both correct and cheap.
  let payload = buildPayload(identity, gvoForkBranch, sourceRepoPath, "",
    branchName, targetSha, repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    # Named-Lock-Files §7.2. A workspace VCS operation materialises a
    # CHECKOUT, and `Workspace-Manifests.md` §"Mode-agnostic" is explicit
    # that develop-vs-store-installed "is never recorded in the lock" — so
    # no solved package instance governs this edge. See
    # `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    text = encodePayload(payload))

proc gitRefreshBareAction*(id: string; identity: GitToolIdentity;
                           remoteUrl, barePath, receiptPath: string;
                           cwd = ""; deps: openArray[string] = [];
                           cacheable = false): BuildAction =
  ## RA-27 — engine action for the RA-5 shared-bare warm-up, so the per-URL
  ## network work runs on the ``vcs/fetch`` pool instead of a serial loop.
  ## ``cacheable = false``: the bare's freshness is live remote state, not a
  ## function of the declared inputs.
  let payload = buildPayload(identity, gvoRefreshBare, remoteUrl, "", "",
    "", barePath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    # Named-Lock-Files §7.2. A workspace VCS operation materialises a
    # CHECKOUT, and `Workspace-Manifests.md` §"Mode-agnostic" is explicit
    # that develop-vs-store-installed "is never recorded in the lock" — so
    # no solved package instance governs this edge. See
    # `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    text = encodePayload(payload))

proc gitMergeFfAction*(id: string; identity: GitToolIdentity;
                      remoteName, branchName, repoPath, receiptPath: string;
                      cwd = ""; deps: openArray[string] = [];
                      cacheable = false): BuildAction =
  ## RA-5c — construct a fast-forward merge action used in the sync/pull
  ## checkout phase. The executor runs ``git merge --ff-only
  ## refs/remotes/<remoteName>/<branchName>`` in the named working tree;
  ## it refuses on a dirty tree or a non-fast-forward relationship. This
  ## replaces the synchronous ``gitRunPlain(["merge", "--ff-only", ...])``
  ## the old serial sync path issued outside the engine: the merge is now
  ## an engine action that can depend on its sibling ``fetch``.
  ##
  ## ``cacheable`` defaults to ``false``: a fast-forward is a mutation of
  ## a working tree whose precondition (HEAD ↔ remote-tip relationship)
  ## is observed live, not a deterministic function of declared inputs,
  ## so caching its receipt would be unsound (mirrors why the query
  ## operations are not cacheable).
  let payload = buildPayload(identity, gvoMergeFf, "", remoteName,
    branchName, "", repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    # Named-Lock-Files §7.2. A workspace VCS operation materialises a
    # CHECKOUT, and `Workspace-Manifests.md` §"Mode-agnostic" is explicit
    # that develop-vs-store-installed "is never recorded in the lock" — so
    # no solved package instance governs this edge. See
    # `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    text = encodePayload(payload))

proc gitForceResetAction*(id: string; identity: GitToolIdentity;
                      revision, repoPath, receiptPath: string;
                      cwd = ""; deps: openArray[string] = [];
                      cacheable = false): BuildAction =
  ## RA-16 ``--force-sync`` — construct the destructive overwrite action
  ## the force path schedules for a divergent / dirty checkout. The
  ## executor runs ``git reset --hard <revision>`` + ``git clean -ffdx``
  ## in the named working tree so it ends byte-identical to a fresh
  ## checkout at the locked SHA.
  ##
  ## ``cacheable`` defaults to ``false``: like ``merge-ff``, the action
  ## mutates a working tree whose precondition (the divergence) is
  ## observed live, not a deterministic function of declared inputs, so
  ## caching its receipt would be unsound.
  let payload = buildPayload(identity, gvoForceReset, "", "",
    "", revision, repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    # Named-Lock-Files §7.2. A workspace VCS operation materialises a
    # CHECKOUT, and `Workspace-Manifests.md` §"Mode-agnostic" is explicit
    # that develop-vs-store-installed "is never recorded in the lock" — so
    # no solved package instance governs this edge. See
    # `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    text = encodePayload(payload))

proc gitForcePushRebaseAction*(id: string; identity: GitToolIdentity;
                              branchName, baseSha, repoPath, receiptPath: string;
                              remoteName: string = "origin";
                              cwd = ""; deps: openArray[string] = [];
                              cacheable = false): BuildAction =
  ## Construct a force-push rebase action. The executor runs
  ## executeForcePushRebase, which resets the branch to the remote branch tip
  ## and cherry-picks the locally authored commits since `baseSha`.
  let payload = buildPayload(identity, gvoForcePushRebase, "", remoteName,
    branchName, "", repoPath, receiptPath, baseSha = baseSha)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    # Named-Lock-Files §7.2. A workspace VCS operation materialises a
    # CHECKOUT, and `Workspace-Manifests.md` §"Mode-agnostic" is explicit
    # that develop-vs-store-installed "is never recorded in the lock" — so
    # no solved package instance governs this edge. See
    # `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    text = encodePayload(payload))

# ---- Query operations (observation-only, per M2 design rule 3) ----

proc headShaQuery*(repoPath: string): GitQueryAction =
  GitQueryAction(kind: gqkHeadSha, repoPath: repoPath)

proc isCleanQuery*(repoPath: string): GitQueryAction =
  GitQueryAction(kind: gqkIsClean, repoPath: repoPath)

proc isPublishedQuery*(repoPath, remoteName: string): GitQueryAction =
  GitQueryAction(kind: gqkIsPublished, repoPath: repoPath,
    remoteName: remoteName)

proc extendedStatusQuery*(repoPath, trunkBranch: string;
                          queryStashes, queryFiles, queryAheadBehind,
                          queryUnmerged: bool;
                          queryFileDetails = false): GitQueryAction =
  GitQueryAction(kind: gqkExtendedStatus, repoPath: repoPath,
    remoteName: "origin", trunkBranch: trunkBranch,
    queryStashes: queryStashes, queryFiles: queryFiles,
    queryAheadBehind: queryAheadBehind, queryUnmerged: queryUnmerged,
    queryFileDetails: queryFileDetails)

proc queryGitState*(query: GitQueryAction;
                    identity: GitToolIdentity): GitQueryResult =
  ## Execute a read-only VCS query against the identity-bound git
  ## binary. The result is the structured artifact the caller folds
  ## into evidence; it is NOT routed through ``runBuild`` because the
  ## result is a property of the working tree at the moment of
  ## observation, not a deterministic function of declared inputs.
  let payload = GitVcsPayload(
    identityDigestHex: identity.digestHex(),
    identityVersion: identity.version,
    binaryPath: identity.binaryPath)
  case query.kind
  of gqkHeadSha:
    let res = resolveHeadSha(payload, query.repoPath)
    if res.ok:
      result = GitQueryResult(status: gqsOk, headSha: res.sha)
    else:
      result = GitQueryResult(status: gqsFailed,
        diagnostic: res.diagnostic)
  of gqkIsClean:
    let res = workingTreeIsClean(payload, query.repoPath)
    if res.ok:
      result = GitQueryResult(status: gqsOk, isClean: res.clean)
    else:
      result = GitQueryResult(status: gqsFailed,
        diagnostic: res.diagnostic)
  of gqkIsPublished:
    let res = remoteBranchContainsHead(payload, query.repoPath,
      query.remoteName)
    if res.ok:
      result = GitQueryResult(status: gqsOk, isPublished: res.published)
    else:
      result = GitQueryResult(status: gqsFailed,
        diagnostic: res.diagnostic)
  of gqkExtendedStatus:
    var headSha = ""
    var isClean = true
    var isPublished = true
    var stashCount = 0
    var aheadCount = 0
    var behindCount = 0
    var untrackedCount = 0
    var modifiedCount = 0
    var unmergedBranches: seq[string] = @[]
    var fileDetails: seq[FileStatusEntry] = @[]
    var diagnostic = ""

    # 1. HEAD SHA
    let headRes = resolveHeadSha(payload, query.repoPath)
    if headRes.ok:
      headSha = headRes.sha
    else:
      diagnostic.add("failed to resolve HEAD SHA: " & headRes.diagnostic)

    # 2. File Status
    if query.queryFiles:
      let statusRes = runGit(payload, ["-C", query.repoPath, "status", "--porcelain"])
      if statusRes.exitCode == 0:
        isClean = true
        for rawLine in statusRes.output.splitLines():
          if rawLine.strip().len == 0: continue
          isClean = false
          # Porcelain v1: the two status columns (index X, worktree Y) are at
          # positions 0-1; the path follows at position 3. The leading columns
          # are SIGNIFICANT (a leading space means "unstaged"), so read them from
          # the RAW line — never `strip()` — to preserve staged/unstaged.
          let xy = if rawLine.len >= 2: rawLine[0 ..< 2] else: rawLine
          let path = if rawLine.len >= 3: rawLine[3 .. ^1] else: ""
          if xy == "??":
            inc untrackedCount
          else:
            inc modifiedCount
          if query.queryFileDetails:
            fileDetails.add(FileStatusEntry(code: xy, path: path))
      else:
        diagnostic.add("; git status failed: " & statusRes.output.trimmed)
    else:
      # If files aren't queried, fall back to simple clean check
      let cleanRes = workingTreeIsClean(payload, query.repoPath)
      if cleanRes.ok:
        isClean = cleanRes.clean
      else:
        diagnostic.add("; clean check failed: " & cleanRes.diagnostic)

    # 3. Published Check
    let pubRes = remoteBranchContainsHead(payload, query.repoPath, query.remoteName)
    if pubRes.ok:
      isPublished = pubRes.published
    else:
      diagnostic.add("; published check failed: " & pubRes.diagnostic)

    # 4. Stashes
    if query.queryStashes:
      let stashRes = runGit(payload, ["-C", query.repoPath, "stash", "list"])
      if stashRes.exitCode == 0:
        for line in stashRes.output.splitLines():
          if line.strip().len > 0:
            inc stashCount

    # 5. Ahead / Behind
    if query.queryAheadBehind:
      let upstreamRes = runGit(payload, ["-C", query.repoPath, "rev-parse", "--abbrev-ref", "@{u}"])
      if upstreamRes.exitCode == 0:
        let upstream = upstreamRes.output.strip()
        let revListRes = runGit(payload, ["-C", query.repoPath, "rev-list", "--count", "--left-right", upstream & "...HEAD"])
        if revListRes.exitCode == 0:
          try:
            let parts = revListRes.output.strip().splitWhitespace()
            if parts.len >= 2:
              behindCount = parseInt(parts[0])
              aheadCount = parseInt(parts[1])
          except CatchableError:
            discard

    # 6. Unmerged Branches
    if query.queryUnmerged:
      let trunkBranch = if query.trunkBranch.len > 0: query.trunkBranch else: "main"
      let unmergedRes = runGit(payload, ["-C", query.repoPath, "branch", "--no-merged", trunkBranch])
      if unmergedRes.exitCode == 0:
        for rawLine in unmergedRes.output.splitLines():
          var line = rawLine.strip()
          # Strip git's current-branch ("* ") / worktree ("+ ") markers.
          if line.startsWith("* ") or line.startsWith("+ "):
            line = line[2 .. ^1].strip()
          # `git branch --no-merged` prints one branch name per line, but runGit
          # merges stderr into stdout (execCmdEx), so a git diagnostic can land
          # here — e.g. "warning: refname '<trunk>' is ambiguous." emitted when
          # the trunk name resolves ambiguously (a repo whose branch is literally
          # named `heads/main` makes bare `main` ambiguous). A real branch name
          # contains no whitespace or ':' and never starts with '(' (the
          # detached-HEAD note), so reject anything else as non-branch noise.
          if line.len == 0 or line == trunkBranch: continue
          if line.startsWith("(") or line.contains(' ') or
             line.contains('\t') or line.contains(':'):
            continue
          unmergedBranches.add(line)

    result = GitQueryResult(
      status: if diagnostic.len == 0: gqsOk else: gqsFailed,
      headSha: headSha,
      isClean: isClean,
      isPublished: isPublished,
      diagnostic: if diagnostic.startsWith("; "): diagnostic[2..^1] else: diagnostic,
      stashCount: stashCount,
      aheadCount: aheadCount,
      behindCount: behindCount,
      untrackedCount: untrackedCount,
      modifiedCount: modifiedCount,
      unmergedBranches: unmergedBranches,
      fileDetails: fileDetails
    )
