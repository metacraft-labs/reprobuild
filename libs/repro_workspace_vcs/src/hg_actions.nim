## Workspace VCS — Mercurial action constructors and executor (M3).
##
## This module is the hg parallel of M2's ``git_actions``. It exposes
## the same primitive VCS operations as typed build actions the
## engine schedules under the existing ``bakWorkspaceVcs`` kind:
##
##   - ``hgCloneAction``  — clone a remote into a target path; writes
##     a small ``clone-receipt`` file as the cacheable output.
##   - ``hgPullAction``   — pull from the cloned origin (``default``
##     path in hg parlance) in an existing working tree; writes a
##     ``pull-receipt`` capturing the post-pull tip identifier.
##     Parallel to M2's ``gitFetchAction``.
##   - ``hgUpdateAction`` — ``hg update`` a branch in an existing
##     working tree, refusing on a dirty tree with the structured
##     reason ``"dirty"`` (mirrors M2's switch-on-dirty contract).
##
## The mutating actions are cacheable. The unit of caching is the
## **receipt** (a small canonical text file) rather than the hg
## working tree itself: caching the receipt lets the engine compute
## determinism without trying to content-address every byte of the
## ``.hg/`` store (per M2 design rule 1, which M3 inherits).
##
## The query operations (``head-sha`` / ``is-clean`` / ``is-published``
## in the spec table) are observation-only and surfaced as a separate
## proc shape that returns a structured ``HgQueryResult`` directly —
## they are NOT expressible as cacheable actions because their output
## is a property of the working tree at the moment of the query (per
## M2 design rule 3).
##
## Every cacheable action constructor accepts a ``HgToolIdentity`` and
## folds its ``digest`` into the action's ``weakFingerprint`` via the
## same length-prefixed codec M2's git actions use. The hg payload
## magic differs from the git payload magic, so the same logical
## parameters in two VCSes can never collide in the action cache
## (per M2 design rule 2).
##
## **Engine seam.** M3 does NOT touch ``repro_build_engine``: the
## ``bakWorkspaceVcs`` kind and the single ``WorkspaceVcsExecutor``
## installed by ``git_actions`` still own dispatch. At module-init
## time we register a hg sub-executor with ``git_actions`` via
## ``registerHgSubExecutor``; the multiplexer in ``git_actions`` reads
## the first line of ``builtinText`` and routes to whichever VCS owns
## the payload magic. Hybrid workspaces (one git repo and one hg repo
## in the same plan) therefore run under a single ``runBuild`` call.

import std/[os, osproc, strutils]

import repro_build_engine
import repro_core/codec
import repro_hash

import git_actions
import hg_tool

export HgToolIdentity, EHgToolUnresolved, ensureHgToolResolvable,
  resolveHgTool, digestHex, ToolProvisioningMode

const
  WorkspaceVcsKindHg* = "hg"
    ## Stable tag stored in receipts so hg artifacts cannot be
    ## confused with git artifacts at restore time. Parallel to
    ## ``WorkspaceVcsKind = "git"`` in ``git_actions``.
  HgCloneReceiptHeader* = "reprobuild.workspace-vcs.hg-clone-receipt.v1"
  HgPullReceiptHeader* = "reprobuild.workspace-vcs.hg-pull-receipt.v1"
  HgUpdateReceiptHeader* = "reprobuild.workspace-vcs.hg-update-receipt.v1"
  HgPayloadVersion* = "reprobuild.workspace-vcs.hg-payload.v1"
    ## First-line magic the dispatcher in ``git_actions`` uses to
    ## route hg actions to this module. The magic differs from git's
    ## ``PayloadVersion`` so the dispatcher can discriminate by
    ## reading a single line.

type
  HgVcsOp* = enum
    hvoClone
    hvoPull
    hvoUpdate

  HgVcsPayload* = object
    ## Compact per-action payload encoded into ``builtinText`` so the
    ## executor can recover the operation parameters from a
    ## ``BuildAction`` alone. Identical encoding shape to
    ## ``GitVcsPayload`` but a distinct magic line so the multiplexer
    ## in ``git_actions`` can route the action without parsing the
    ## body.
    op*: HgVcsOp
    remoteUrl*: string
    branchName*: string
    revision*: string
    repoPath*: string
    receiptPath*: string
    identityDigestHex*: string
    identityVersion*: string
    binaryPath*: string

  HgQueryKind* = enum
    hqkHeadSha
    hqkIsClean
    hqkIsPublished

  HgQueryAction* = object
    ## Observation-only descriptor for the read-only query operations.
    ## NOT a BuildAction: these queries do NOT participate in the
    ## action cache (M2 design rule 3, inherited) and call sites
    ## consume the ``HgQueryResult`` directly.
    kind*: HgQueryKind
    repoPath*: string

  HgQueryStatus* = enum
    hqsOk
    hqsFailed

  HgQueryResult* = object
    status*: HgQueryStatus
    headSha*: string
    isClean*: bool
    isPublished*: bool
    diagnostic*: string

proc opTag(op: HgVcsOp): string =
  case op
  of hvoClone: "clone"
  of hvoPull: "pull"
  of hvoUpdate: "update"

proc parseOpTag(tag: string): HgVcsOp =
  case tag
  of "clone": hvoClone
  of "pull": hvoPull
  of "update": hvoUpdate
  else:
    raise newException(ValueError,
      "unknown hg workspace-vcs operation tag: " & tag)

proc encodePayload(payload: HgVcsPayload): string =
  ## Encode the payload as a small key=value line list. The encoder
  ## escapes ``\`` and newline so values with embedded newlines cannot
  ## inject phantom fields.
  proc esc(value: string): string =
    result = newStringOfCap(value.len)
    for ch in value:
      case ch
      of '\\': result.add("\\\\")
      of '\n': result.add("\\n")
      else: result.add(ch)

  result = HgPayloadVersion & "\n"
  result.add("op=" & opTag(payload.op) & "\n")
  result.add("remote-url=" & esc(payload.remoteUrl) & "\n")
  result.add("branch=" & esc(payload.branchName) & "\n")
  result.add("revision=" & esc(payload.revision) & "\n")
  result.add("repo-path=" & esc(payload.repoPath) & "\n")
  result.add("receipt-path=" & esc(payload.receiptPath) & "\n")
  result.add("identity-digest=" & payload.identityDigestHex & "\n")
  result.add("identity-version=" & esc(payload.identityVersion) & "\n")
  result.add("binary-path=" & esc(payload.binaryPath) & "\n")

proc decodePayload(text: string): HgVcsPayload =
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
  if lines.len == 0 or lines[0] != HgPayloadVersion:
    raise newException(ValueError,
      "hg workspace-vcs payload missing magic header (expected " &
        HgPayloadVersion & ")")
  for line in lines[1 .. ^1]:
    if line.len == 0:
      continue
    let eq = line.find('=')
    if eq < 0:
      raise newException(ValueError,
        "hg workspace-vcs payload line missing '=': " & line)
    let key = line[0 ..< eq]
    let value = unesc(line[eq + 1 .. ^1])
    case key
    of "op": result.op = parseOpTag(value)
    of "remote-url": result.remoteUrl = value
    of "branch": result.branchName = value
    of "revision": result.revision = value
    of "repo-path": result.repoPath = value
    of "receipt-path": result.receiptPath = value
    of "identity-digest": result.identityDigestHex = value
    of "identity-version": result.identityVersion = value
    of "binary-path": result.binaryPath = value
    else:
      # Forward-compatible: ignore unknown keys so a payload written
      # by a newer M3.x build still decodes.
      discard

proc fingerprintPayload(payload: HgVcsPayload): seq[byte] =
  ## Build the fingerprint payload that will be hashed under
  ## ``hdActionFingerprint``. Two clones with the same logical
  ## parameters but different temp roots still produce the same
  ## digest (the local path is omitted from the clone fingerprint,
  ## same as M2 for git).
  result = @[]
  result.writeString("reprobuild.workspace-vcs.hg-fingerprint.v1")
  result.writeString(WorkspaceVcsKindHg)
  result.writeString(opTag(payload.op))
  result.writeString(payload.identityDigestHex)
  result.writeString(payload.remoteUrl)
  result.writeString(payload.branchName)
  result.writeString(payload.revision)
  case payload.op
  of hvoClone:
    discard
  of hvoPull, hvoUpdate:
    result.writeString(payload.repoPath)

proc actionFingerprint*(payload: HgVcsPayload): ContentDigest =
  blake3DomainDigest(fingerprintPayload(payload), hdActionFingerprint)

proc payloadFromAction*(action: BuildAction): HgVcsPayload =
  if action.kind != bakWorkspaceVcs:
    raise newException(ValueError,
      "payloadFromAction expects a bakWorkspaceVcs action: got " &
        $action.kind)
  decodePayload(action.builtinText)

proc absoluteRepoPath(payload: HgVcsPayload; cwd: string): string =
  if payload.repoPath.isAbsolute:
    payload.repoPath
  elif cwd.len > 0:
    cwd / payload.repoPath
  else:
    payload.repoPath

proc runHg(payload: HgVcsPayload; args: openArray[string];
           workingDir = ""): tuple[exitCode: int; output: string] =
  ## Invoke the identity-bound hg binary with the requested arguments.
  ## We use ``execCmdEx`` to mirror M2's subprocess shape (no new
  ## third-party dependency, per the M3 hard constraint).
  ##
  ## We always pass ``--config ui.interactive=False`` so hg never
  ## stalls on a hypothetical credential prompt — relevant only in the
  ## "remote URL turned out to need auth" failure path, but cheap
  ## insurance.
  var cmd = quoteShell(payload.binaryPath)
  cmd.add(" --config ui.interactive=False")
  for arg in args:
    cmd.add(" ")
    cmd.add(quoteShell(arg))
  let res = execCmdEx(cmd, workingDir = workingDir)
  (exitCode: res.exitCode, output: res.output)

proc trimmed(value: string): string = value.strip()

proc resolveTipId(payload: HgVcsPayload; repoPath: string): tuple[ok: bool; sha: string; diagnostic: string] =
  ## hg's analogue of ``git rev-parse HEAD``: ``hg id -i`` prints the
  ## short id of the parent of the working directory (or of tip when
  ## no working dir exists, e.g. ``hg clone -U``). The ``+`` suffix
  ## that hg appends on a dirty working dir is stripped at the caller
  ## (we want pure hex here).
  let res = runHg(payload, ["-R", repoPath, "id", "-i"])
  if res.exitCode != 0:
    return (ok: false, sha: "",
      diagnostic: "hg id -i failed (" & $res.exitCode & "): " &
        res.output.trimmed)
  var sha = res.output.trimmed
  if sha.endsWith("+"):
    sha = sha[0 ..< sha.len - 1]
  (ok: true, sha: sha, diagnostic: "")

proc workingTreeIsClean(payload: HgVcsPayload; repoPath: string): tuple[ok: bool; clean: bool; diagnostic: string] =
  let res = runHg(payload, ["-R", repoPath, "status"])
  if res.exitCode != 0:
    return (ok: false, clean: false,
      diagnostic: "hg status failed (" & $res.exitCode & "): " &
        res.output.trimmed)
  (ok: true, clean: res.output.strip.len == 0, diagnostic: "")

proc headIsPublished(payload: HgVcsPayload; repoPath: string): tuple[ok: bool; published: bool; diagnostic: string] =
  ## ``hg log -r 'ancestors(.) and public()'`` returns the public
  ## ancestors of the working-dir parent. We ask for ``--template
  ## {node}\n`` and treat any non-empty output as "yes, the current
  ## head sits on a public ancestor chain" (i.e. is published in
  ## hg's phase model). A clean local-only working dir on a draft
  ## phase produces empty output and so reads as unpublished — this
  ## matches the M2 git contract (no remote-tracking branch contains
  ## HEAD).
  let res = runHg(payload,
    ["-R", repoPath, "log",
     "-r", "ancestors(.) and public()",
     "--template", "{node}\n"])
  if res.exitCode != 0:
    return (ok: false, published: false,
      diagnostic: "hg log (public ancestors) failed (" &
        $res.exitCode & "): " & res.output.trimmed)
  (ok: true, published: res.output.strip.len > 0, diagnostic: "")

proc writeReceipt(receiptPath, content: string) =
  createDir(receiptPath.splitPath.head)
  writeFile(receiptPath, content)

proc renderCloneReceipt(payload: HgVcsPayload; headSha: string): string =
  result = HgCloneReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKindHg & "\n")
  result.add("operation\tclone\n")
  result.add("remote-url\t" & payload.remoteUrl & "\n")
  result.add("revision\t" & payload.revision & "\n")
  result.add("head-sha\t" & headSha & "\n")
  result.add("hg-version\t" & payload.identityVersion & "\n")
  result.add("hg-identity\t" & payload.identityDigestHex & "\n")

proc renderPullReceipt(payload: HgVcsPayload; headSha, pullOutput: string): string =
  result = HgPullReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKindHg & "\n")
  result.add("operation\tpull\n")
  result.add("repo-path\t" & payload.repoPath & "\n")
  result.add("head-sha\t" & headSha & "\n")
  result.add("hg-version\t" & payload.identityVersion & "\n")
  result.add("hg-identity\t" & payload.identityDigestHex & "\n")
  result.add("pull-output\t" &
    pullOutput.replace("\n", " ").strip() & "\n")

proc renderUpdateReceipt(payload: HgVcsPayload; headSha: string): string =
  result = HgUpdateReceiptHeader & "\n"
  result.add("kind\t" & WorkspaceVcsKindHg & "\n")
  result.add("operation\tupdate\n")
  result.add("branch\t" & payload.branchName & "\n")
  result.add("repo-path\t" & payload.repoPath & "\n")
  result.add("head-sha\t" & headSha & "\n")
  result.add("hg-version\t" & payload.identityVersion & "\n")
  result.add("hg-identity\t" & payload.identityDigestHex & "\n")

proc failed(reason, diagnostic: string): ActionResult =
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

proc executeClone(payload: HgVcsPayload; cwd, receiptPath: string): ActionResult =
  let target = absoluteRepoPath(payload, cwd)
  let parent = target.splitPath.head
  if parent.len > 0:
    createDir(parent)
  if dirExists(target):
    # A pre-existing target is a hard error: clone must be the act of
    # creating the working tree. The CLI-level "init-or-resync" flow
    # will be a different action (M9+). Same contract as git's clone
    # arm.
    return failed("clone-target-exists",
      "clone target already exists: " & target)
  var args = @["clone"]
  if payload.revision.len > 0:
    # ``--branch`` and ``--rev`` differ in hg: ``--branch`` follows
    # the named branch (heads only), ``--rev`` pins to one changeset.
    # The M3 surface uses ``revision`` to mean "branch name or
    # bookmark" (mirroring how git's ``revision`` argument is treated
    # by ``git clone --branch``), so we route it through ``--branch``.
    args.add("--branch")
    args.add(payload.revision)
  args.add(payload.remoteUrl)
  args.add(target)
  let cloneRes = runHg(payload, args)
  if cloneRes.exitCode != 0:
    return failed("clone-failed",
      "hg clone exited " & $cloneRes.exitCode & ": " &
        cloneRes.output.trimmed)
  let headRes = resolveTipId(payload, target)
  if not headRes.ok:
    return failed("clone-head-probe-failed", headRes.diagnostic)
  let receipt = renderCloneReceipt(payload, headRes.sha)
  writeReceipt(receiptPath, receipt)
  succeeded()

proc executePull(payload: HgVcsPayload; cwd, receiptPath: string): ActionResult =
  let target = absoluteRepoPath(payload, cwd)
  if not dirExists(target / ".hg"):
    return failed("pull-target-missing",
      "pull target is not a hg working tree: " & target)
  # ``hg pull`` defaults to the ``default`` path recorded at clone
  # time, which is the analogue of git's ``origin`` for our purposes.
  let res = runHg(payload, ["-R", target, "pull"])
  if res.exitCode != 0:
    return failed("pull-failed",
      "hg pull exited " & $res.exitCode & ": " & res.output.trimmed)
  let headRes = resolveTipId(payload, target)
  if not headRes.ok:
    return failed("pull-head-probe-failed", headRes.diagnostic)
  let receipt = renderPullReceipt(payload, headRes.sha, res.output)
  writeReceipt(receiptPath, receipt)
  succeeded()

proc executeUpdate(payload: HgVcsPayload; cwd, receiptPath: string): ActionResult =
  let target = absoluteRepoPath(payload, cwd)
  if not dirExists(target / ".hg"):
    return failed("update-target-missing",
      "update target is not a hg working tree: " & target)
  # Refuse on a dirty tree BEFORE invoking hg update — the contract
  # field is ``reason = "dirty"``, mirroring the M2 git-switch
  # contract. We deliberately do NOT string-match against hg's
  # human-facing output (which differs by version).
  let cleanRes = workingTreeIsClean(payload, target)
  if not cleanRes.ok:
    return failed("update-status-probe-failed", cleanRes.diagnostic)
  if not cleanRes.clean:
    return failed("dirty",
      "hg update refused: working tree is dirty at " & target)
  let res = runHg(payload, ["-R", target, "update", payload.branchName])
  if res.exitCode != 0:
    return failed("update-failed",
      "hg update exited " & $res.exitCode & ": " & res.output.trimmed)
  let headRes = resolveTipId(payload, target)
  if not headRes.ok:
    return failed("update-head-probe-failed", headRes.diagnostic)
  let receipt = renderUpdateReceipt(payload, headRes.sha)
  writeReceipt(receiptPath, receipt)
  succeeded()

proc executeHgVcsAction(action: BuildAction): ActionResult {.gcsafe.} =
  ## The sub-executor the multiplexer in ``git_actions`` invokes for
  ## hg payloads. We do NOT register a separate
  ## ``WorkspaceVcsExecutor`` with the engine — the engine sees a
  ## single dispatcher (installed by ``git_actions``) which routes to
  ## us via the payload magic.
  var payload: HgVcsPayload
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
  of hvoClone: result = executeClone(payload, action.cwd, receiptPath)
  of hvoPull: result = executePull(payload, action.cwd, receiptPath)
  of hvoUpdate: result = executeUpdate(payload, action.cwd, receiptPath)
  result.id = action.id

proc installHgVcsExecutor*() =
  ## Explicit entry point so tests that need a fresh executor binding
  ## can re-install it (e.g. after ``clearWorkspaceVcsExecutor`` +
  ## ``clearHgSubExecutor``).
  registerHgSubExecutor(HgPayloadVersion, executeHgVcsAction)

# Install at module init time so any caller that simply imports
# ``hg_actions`` and constructs an action via the helpers below gets a
# working dispatch automatically (alongside git's, which
# ``git_actions``'s own module-init has already installed via
# transitive import).
installHgVcsExecutor()

proc buildPayload(identity: HgToolIdentity; op: HgVcsOp;
                  remoteUrl, branchName, revision,
                  repoPath, receiptPath: string): HgVcsPayload =
  HgVcsPayload(
    op: op,
    remoteUrl: remoteUrl,
    branchName: branchName,
    revision: revision,
    repoPath: repoPath,
    receiptPath: receiptPath,
    identityDigestHex: identity.digestHex(),
    identityVersion: identity.version,
    binaryPath: identity.binaryPath)

proc hgCloneAction*(id: string; identity: HgToolIdentity;
                    remoteUrl, repoPath, receiptPath: string;
                    revision = ""; cwd = ""; deps: openArray[string] = [];
                    cacheable = true): BuildAction =
  ## Construct a cacheable hg clone action. The receipt path is the
  ## action's declared output and the unit of caching (per M2 design
  ## rule 1, inherited). ``revision``, when non-empty, is passed as
  ## ``--branch`` to ``hg clone`` (matching the git analogue's
  ## treatment).
  ##
  ## The action fingerprint folds the ``HgToolIdentity.digest`` so two
  ## workspaces resolving to different hg binaries cannot share a
  ## cache entry (per M2 design rule 2, inherited).
  let payload = buildPayload(identity, hvoClone, remoteUrl, "",
    revision, repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    text = encodePayload(payload))

proc hgPullAction*(id: string; identity: HgToolIdentity;
                   repoPath, receiptPath: string;
                   cwd = ""; deps: openArray[string] = [];
                   cacheable = true): BuildAction =
  ## Construct a cacheable hg pull action. ``hg pull`` defaults to
  ## the ``default`` path recorded at clone time, which is the
  ## analogue of git's ``origin``. The fingerprint includes the
  ## ``repoPath`` because pull is a working-tree-local operation:
  ## two workspaces with the same default path but different working
  ## trees must NOT share a cache entry.
  let payload = buildPayload(identity, hvoPull, "", "", "",
    repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    text = encodePayload(payload))

proc hgUpdateAction*(id: string; identity: HgToolIdentity;
                     branchName, repoPath, receiptPath: string;
                     cwd = ""; deps: openArray[string] = [];
                     cacheable = true): BuildAction =
  ## Construct a cacheable hg update action. The executor refuses on
  ## a dirty working tree and surfaces ``reason = "dirty"`` via the
  ## ``ActionResult`` (mirrors the M2 git-switch contract).
  let payload = buildPayload(identity, hvoUpdate, "", branchName, "",
    repoPath, receiptPath)
  result = builtinAction(bakWorkspaceVcs, id, cwd = cwd,
    deps = deps, outputs = @[receiptPath], cacheable = cacheable,
    weakFingerprint = actionFingerprint(payload),
    text = encodePayload(payload))

# ---- Query operations (observation-only, per M2 design rule 3) ----

proc headShaQuery*(repoPath: string): HgQueryAction =
  HgQueryAction(kind: hqkHeadSha, repoPath: repoPath)

proc isCleanQuery*(repoPath: string): HgQueryAction =
  HgQueryAction(kind: hqkIsClean, repoPath: repoPath)

proc isPublishedQuery*(repoPath: string): HgQueryAction =
  HgQueryAction(kind: hqkIsPublished, repoPath: repoPath)

proc queryHgState*(query: HgQueryAction;
                   identity: HgToolIdentity): HgQueryResult =
  ## Execute a read-only hg query against the identity-bound hg
  ## binary. The result is the structured artifact the caller folds
  ## into evidence; it is NOT routed through ``runBuild`` because the
  ## result is a property of the working tree at the moment of
  ## observation, not a deterministic function of declared inputs.
  let payload = HgVcsPayload(
    identityDigestHex: identity.digestHex(),
    identityVersion: identity.version,
    binaryPath: identity.binaryPath)
  case query.kind
  of hqkHeadSha:
    let res = resolveTipId(payload, query.repoPath)
    if res.ok:
      result = HgQueryResult(status: hqsOk, headSha: res.sha)
    else:
      result = HgQueryResult(status: hqsFailed, diagnostic: res.diagnostic)
  of hqkIsClean:
    let res = workingTreeIsClean(payload, query.repoPath)
    if res.ok:
      result = HgQueryResult(status: hqsOk, isClean: res.clean)
    else:
      result = HgQueryResult(status: hqsFailed, diagnostic: res.diagnostic)
  of hqkIsPublished:
    let res = headIsPublished(payload, query.repoPath)
    if res.ok:
      result = HgQueryResult(status: hqsOk, isPublished: res.published)
    else:
      result = HgQueryResult(status: hqsFailed, diagnostic: res.diagnostic)
