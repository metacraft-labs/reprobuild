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

type
  GitVcsOp* = enum
    gvoClone
    gvoFetch
    gvoSwitch

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

  GitQueryKind* = enum
    gqkHeadSha
    gqkIsClean
    gqkIsPublished

  GitQueryAction* = object
    ## Observation-only descriptor for the read-only query operations
    ## (head-sha, is-clean, is-published). NOT a BuildAction: these
    ## queries do NOT participate in the action cache (M2 design rule
    ## 3) and call sites consume the ``GitQueryResult`` directly.
    kind*: GitQueryKind
    repoPath*: string
    remoteName*: string

  GitQueryStatus* = enum
    gqsOk
    gqsFailed

  GitQueryResult* = object
    status*: GitQueryStatus
    headSha*: string
    isClean*: bool
    isPublished*: bool
    diagnostic*: string

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

proc parseOpTag(tag: string): GitVcsOp =
  case tag
  of "clone": gvoClone
  of "fetch": gvoFetch
  of "switch": gvoSwitch
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
  # ``repoPath`` participates in fetch/switch fingerprints (those are
  # working-tree-local operations) but NOT in clone (M2 design rule 1:
  # the clone receipt for the same (remote, revision, identity) must
  # be a cache hit across two parallel temp roots).
  case payload.op
  of gvoClone:
    discard
  of gvoFetch, gvoSwitch:
    result.writeString(payload.repoPath)

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
  let res = execCmdEx(cmd, workingDir = workingDir)
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
  let lookup = runGit(payload,
    ["-C", repoPath, "branch", "-r", "--contains", "HEAD"])
  if lookup.exitCode != 0:
    return (ok: false, published: false,
      diagnostic: "git branch -r --contains HEAD failed (" &
        $lookup.exitCode & "): " & lookup.output.trimmed)
  let needle = remote & "/"
  for raw in lookup.output.splitLines:
    let line = raw.strip()
    if line.len == 0:
      continue
    # Lines look like ``  origin/main`` or ``* origin/HEAD -> origin/main``.
    let normalized = line.replace("* ", "").strip()
    if normalized.startsWith(needle):
      return (ok: true, published: true, diagnostic: "")
    # ``HEAD -> origin/main`` form: split on " -> " and re-check.
    let arrowIndex = normalized.find(" -> ")
    if arrowIndex >= 0:
      let tail = normalized[arrowIndex + 4 .. ^1].strip()
      if tail.startsWith(needle):
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
  result.add("fetch-output\t" &
    fetchOutput.replace("\n", " ").strip() & "\n")

proc renderSwitchReceipt(payload: GitVcsPayload; headSha: string): string =
  result = SwitchReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKind & "\n")
  result.add("operation\tswitch\n")
  result.add("branch\t" & payload.branchName & "\n")
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

proc executeClone(payload: GitVcsPayload; cwd, receiptPath: string): ActionResult =
  let target = absoluteRepoPath(payload, cwd)
  let parent = target.splitPath.head
  if parent.len > 0:
    createDir(parent)
  if dirExists(target):
    # A pre-existing target is a hard error: clone must be the act of
    # creating the working tree. The CLI-level "init-or-resync" flow
    # will be a different action (M9+).
    return failed("clone-target-exists",
      "clone target already exists: " & target)
  var args = @["clone", payload.remoteUrl, target]
  if payload.revision.len > 0:
    args.add("--branch")
    args.add(payload.revision)
  let cloneRes = runGit(payload, args)
  if cloneRes.exitCode != 0:
    return failed("clone-failed",
      "git clone exited " & $cloneRes.exitCode & ": " &
        cloneRes.output.trimmed)
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
  let res = runGit(payload, ["-C", target, "fetch", payload.remoteName])
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

var hgSubExecutor {.threadvar.}: WorkspaceVcsSubExecutor
var hgSubMagic {.threadvar.}: string

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
    if hgSubExecutor.isNil or magic != hgSubMagic:
      return failed("payload-decode-failed",
        "bakWorkspaceVcs payload magic " & magic &
          " is not handled by any registered VCS sub-executor" &
          " (expected " & PayloadVersion &
          (if hgSubMagic.len > 0: " or " & hgSubMagic else: "") & ")")
    var subResult = hgSubExecutor(action)
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
                  repoPath, receiptPath: string): GitVcsPayload =
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
    binaryPath: identity.binaryPath)

proc gitCloneAction*(id: string; identity: GitToolIdentity;
                     remoteUrl, repoPath, receiptPath: string;
                     revision = ""; cwd = ""; deps: openArray[string] = [];
                     cacheable = true): BuildAction =
  ## Construct a cacheable clone action. The receipt path is the
  ## action's declared output and the unit of caching (per M2 design
  ## rule 1). ``revision``, when non-empty, is passed as ``--branch``
  ## to ``git clone``.
  ##
  ## The action fingerprint folds the ``GitToolIdentity.digest`` so
  ## two workspaces resolving to different git binaries cannot share
  ## a cache entry (per M2 design rule 2).
  let payload = buildPayload(identity, gvoClone, remoteUrl, "", "",
    revision, repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    text = encodePayload(payload))

proc gitFetchAction*(id: string; identity: GitToolIdentity;
                     remoteName, repoPath, receiptPath: string;
                     cwd = ""; deps: openArray[string] = [];
                     cacheable = true): BuildAction =
  ## Construct a cacheable fetch action. The fingerprint includes the
  ## ``repoPath`` because a fetch is a working-tree-local operation:
  ## two workspaces with the same remote name but different working
  ## trees must NOT share a cache entry.
  let payload = buildPayload(identity, gvoFetch, "", remoteName, "",
    "", repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    text = encodePayload(payload))

proc gitSwitchAction*(id: string; identity: GitToolIdentity;
                      branchName, repoPath, receiptPath: string;
                      cwd = ""; deps: openArray[string] = [];
                      cacheable = true): BuildAction =
  ## Construct a cacheable switch action. The executor refuses on a
  ## dirty working tree and surfaces ``reason = "dirty"`` via the
  ## ``ActionResult`` (per M2 design rule 4).
  let payload = buildPayload(identity, gvoSwitch, "", "", branchName,
    "", repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    text = encodePayload(payload))

# ---- Query operations (observation-only, per M2 design rule 3) ----

proc headShaQuery*(repoPath: string): GitQueryAction =
  GitQueryAction(kind: gqkHeadSha, repoPath: repoPath)

proc isCleanQuery*(repoPath: string): GitQueryAction =
  GitQueryAction(kind: gqkIsClean, repoPath: repoPath)

proc isPublishedQuery*(repoPath, remoteName: string): GitQueryAction =
  GitQueryAction(kind: gqkIsPublished, repoPath: repoPath,
    remoteName: remoteName)

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
