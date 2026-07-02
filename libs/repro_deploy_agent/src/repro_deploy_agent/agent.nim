## Windows-Runner-Binary-Cache-Deploy M5 — the reprobuild deploy agent.
##
## A signed desired-state manifest PULL LOOP: the reprobuild-native analog
## of the Linux ``mcl-deploy-agent`` (nixos-modules
## ``packages/mcl/src/mcl/commands/deploy_agent.d``). One agent tick:
##
##   1. POLL every configured manifest source. A source is an HTTP(S) URL
##      (fetched with ``std/httpclient``), a ``file://`` URL, or a plain
##      local filesystem path (both read straight off disk — the hermetic
##      test path). A 404 on an HTTP source is a soft miss (no manifest yet
##      → wait), any other fetch error is a hard, retryable failure.
##   2. DECODE each fetched manifest (the ``RDM1`` envelope).
##   3. VERIFY each manifest against the ALLOWED-SIGNERS set: the signature
##      must verify AND the producer pubkey must be a trust anchor. A
##      manifest for a DIFFERENT target is IGNORED (per-target schema). A
##      manifest that fails verification is REJECTED (never applied) and
##      surfaces a verification error.
##   4. SELECT the HIGHEST valid ``sequence`` among the trusted, this-target
##      manifests. If two share the highest sequence but differ in
##      ``deploymentId`` the desired state is AMBIGUOUS → non-retryable.
##   5. MONOTONICITY: compare the selected sequence with the persisted
##      ``last-applied-sequence`` for this target. If it is <= the persisted
##      value the desired state is already reached → NO re-apply. Only a
##      STRICTLY HIGHER sequence is applied.
##   6. APPLY via the injected apply hook (production: the M4
##      ``runInfraApply`` path with build-action outputs substituted from
##      the binary cache). On success, PERSIST the new last-applied-sequence
##      so the next tick short-circuits.
##
## The apply itself is INJECTED (``ApplyHook``) so the poll/verify/monotonic
## core is testable hermetically AND the production wiring drives the real
## ``runInfraApply``. This mirrors the Linux agent's ``DeployAgentDependencies``
## seam (fetch/run/query process runners injected for tests).

import std/[algorithm, httpclient, os, strutils, uri]

import ./manifest
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

type
  AgentOutcomeKind* = enum
    aoWaiting          ## no manifest for this target yet (all sources missed)
    aoConverged        ## selected sequence <= last-applied; nothing to do
    aoApplied          ## a strictly-higher valid sequence was applied
    aoRejected         ## a manifest failed signature/trust verification
    aoAmbiguous        ## two manifests tie on the highest sequence
    aoSourceError      ## a source read/fetch failed (retryable)
    aoApplyFailed      ## the apply hook returned failure

  AgentOutcome* = object
    kind*: AgentOutcomeKind
    target*: string
    sequence*: uint64          ## the selected/applied sequence (0 if none)
    deploymentId*: string
    message*: string
    errorCode*: string

  ApplyHook* = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.}
    ## Injected apply. Production wires the M4 ``runInfraApply`` path
    ## (see ``runInfraApplyHook``); tests inject a recording hook. Returns
    ## ``ok = true`` when the desired state converged.

  AgentConfig* = object
    ## One agent invocation's configuration. Mirrors the Linux agent's
    ## ``services.mcl-deploy-agent`` option surface (target, sources,
    ## allowed-signers, state dir).
    target*: string
    sources*: seq[string]        ## HTTP(S) URLs, file:// URLs, or plain paths
    anchors*: peerAuth.TrustAnchors
    stateDir*: string            ## durable last-applied-sequence lives here
    fetchTimeoutMs*: int

  AgentDeps* = object
    ## Test seam. ``apply`` is the apply hook. ``httpGet`` overrides the
    ## HTTP fetch (nil ⇒ the real ``std/httpclient`` path). The hermetic
    ## gates use plain-path sources so they never touch ``httpGet``.
    apply*: ApplyHook
    httpGet*: proc(url: string; timeoutMs: int):
      tuple[ok: bool; missing: bool; body: seq[byte]; error: string] {.gcsafe.}

  Candidate = object
    source: string
    manifest: DeployManifest

# ---------------------------------------------------------------------------
# Last-applied-sequence persistence.
#
# A tiny durable file per target: ``<stateDir>/deploy-agent/<safe-target>.seq``
# holds the highest sequence ever successfully applied for that target. The
# monotonic gate reads it before deciding to apply and rewrites it after a
# successful apply. Absent file ⇒ nothing applied yet (sequence 0 floor).
# ---------------------------------------------------------------------------

proc safeTargetName(target: string): string =
  ## Filesystem-safe rendering of a target name (mirrors the Linux
  ## agent's ``safeTargetName``): keep alnum/._-, replace the rest.
  result = newStringOfCap(target.len)
  for ch in target:
    if ch.isAlphaNumeric() or ch in {'.', '_', '-'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "unnamed"

proc sequenceStatePath*(cfg: AgentConfig): string =
  cfg.stateDir / "deploy-agent" / (safeTargetName(cfg.target) & ".seq")

proc readLastAppliedSequence*(cfg: AgentConfig): uint64 =
  ## The highest sequence ever applied for this target, or 0 when none.
  let path = sequenceStatePath(cfg)
  if not fileExists(path):
    return 0'u64
  let text = readFile(path).strip()
  if text.len == 0:
    return 0'u64
  try:
    result = parseBiggestUInt(text)
  except ValueError:
    # A corrupt state file must not silently allow re-applying an older
    # sequence; treat it as "unknown" but fail-safe HIGH so we don't
    # regress. Callers only ever WRITE a valid decimal, so this is a
    # tamper/corruption guard.
    raise newException(CatchableError,
      "corrupt last-applied-sequence state at " & path & ": " & text)

proc writeLastAppliedSequence*(cfg: AgentConfig; sequence: uint64) =
  let path = sequenceStatePath(cfg)
  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)
  writeFile(path, $sequence & "\n")

# ---------------------------------------------------------------------------
# Source reading (HTTP(S) / file:// / plain path).
# ---------------------------------------------------------------------------

proc isHttpSource(source: string): bool =
  source.startsWith("http://") or source.startsWith("https://")

proc isFileUrl(source: string): bool =
  source.startsWith("file://")

proc fileUrlToPath(source: string): string =
  ## ``file:///abs/path`` → ``/abs/path``. Tolerates ``file://host/path``
  ## by taking the path component of the parsed URI.
  let u = parseUri(source)
  result = u.path
  when defined(windows):
    # ``file:///C:/x`` parses to ``/C:/x`` — strip the leading slash.
    if result.len >= 3 and result[0] == '/' and result[2] == ':':
      result = result[1 .. ^1]

proc defaultHttpGet(url: string; timeoutMs: int):
    tuple[ok: bool; missing: bool; body: seq[byte]; error: string] {.gcsafe.} =
  var client = newHttpClient(timeout = (if timeoutMs > 0: timeoutMs else: -1))
  try:
    let resp = client.get(url)
    if resp.code == Http404:
      return (ok: false, missing: true, body: @[], error: "404")
    if not resp.code.is2xx:
      return (ok: false, missing: false, body: @[],
              error: "HTTP " & $resp.code)
    let bodyStr = resp.body
    var bytes = newSeq[byte](bodyStr.len)
    for i, ch in bodyStr:
      bytes[i] = byte(ch)
    return (ok: true, missing: false, body: bytes, error: "")
  except CatchableError as e:
    return (ok: false, missing: false, body: @[], error: e.msg)
  finally:
    try: client.close() except CatchableError: discard

proc readSource(cfg: AgentConfig; deps: AgentDeps; source: string):
    tuple[ok: bool; missing: bool; body: seq[byte]; error: string] =
  ## Returns ``missing = true`` when the source legitimately has no
  ## manifest yet (HTTP 404 or an absent local file) — a soft miss the
  ## agent waits through, not a hard error.
  if isHttpSource(source):
    let getter = if deps.httpGet != nil: deps.httpGet else: defaultHttpGet
    return getter(source, cfg.fetchTimeoutMs)
  let path = if isFileUrl(source): fileUrlToPath(source) else: source
  if not fileExists(path):
    return (ok: false, missing: true, body: @[], error: "no file at " & path)
  try:
    let text = readFile(path)
    var bytes = newSeq[byte](text.len)
    for i, ch in text:
      bytes[i] = byte(ch)
    return (ok: true, missing: false, body: bytes, error: "")
  except CatchableError as e:
    return (ok: false, missing: false, body: @[], error: e.msg)

# ---------------------------------------------------------------------------
# The tick.
# ---------------------------------------------------------------------------

proc runAgentTick*(cfg: AgentConfig; deps: AgentDeps): AgentOutcome =
  ## One poll+verify+apply pass. Pure with respect to injected deps —
  ## the only side effects are the durable last-applied-sequence file
  ## (on a successful apply) and whatever ``deps.apply`` does.
  doAssert cfg.target.len > 0, "agent target must be set"
  doAssert not cfg.anchors.isNil, "agent allowed-signers must be set"
  doAssert deps.apply != nil, "agent apply hook must be set"

  var trusted: seq[Candidate] = @[]
  # -- POLL + DECODE + VERIFY --------------------------------------------
  for source in cfg.sources:
    let r = readSource(cfg, deps, source)
    if r.missing:
      continue                     # soft miss — no manifest at this source
    if not r.ok:
      return AgentOutcome(kind: aoSourceError, target: cfg.target,
        message: "source read failed for " & source & ": " & r.error,
        errorCode: "source_read_failed")
    var m: DeployManifest
    try:
      m = decodeManifest(r.body)
    except CatchableError as e:
      return AgentOutcome(kind: aoRejected, target: cfg.target,
        message: "manifest decode failed for " & source & ": " & e.msg,
        errorCode: "malformed_manifest")
    # Per-target schema: a manifest for another target is IGNORED. This
    # is not an error — a shared source may carry many targets.
    if m.target != cfg.target:
      continue
    # TRUST GATE: signature verifies AND signer is an allowed signer.
    if not verifyTrusted(m, cfg.anchors):
      # Distinguish "bad crypto" from "untrusted key" for the diagnostic.
      let why =
        if verifySignature(m):
          "signed by a key that is NOT in the allowed-signers set"
        else:
          "signature verification failed (tampered or wrong key)"
      return AgentOutcome(kind: aoRejected, target: cfg.target,
        sequence: m.sequence, deploymentId: m.deploymentId,
        message: "manifest from " & source & " REJECTED: " & why,
        errorCode: "verification_failed")
    trusted.add(Candidate(source: source, manifest: m))

  if trusted.len == 0:
    return AgentOutcome(kind: aoWaiting, target: cfg.target,
      message: "no desired-state manifest for target " & cfg.target)

  # -- SELECT HIGHEST VALID SEQUENCE -------------------------------------
  trusted.sort(proc (a, b: Candidate): int =
    cmp(a.manifest.sequence, b.manifest.sequence))
  let selected = trusted[^1].manifest
  # Ambiguity: another candidate ties the highest sequence with a
  # DIFFERENT deploymentId ⇒ the desired state is not well-defined.
  for c in trusted:
    if c.manifest.sequence == selected.sequence and
       c.manifest.deploymentId != selected.deploymentId:
      return AgentOutcome(kind: aoAmbiguous, target: cfg.target,
        sequence: selected.sequence,
        message: "ambiguous desired state: multiple deployments share " &
          "sequence " & $selected.sequence,
        errorCode: "ambiguous_sequence")

  # -- MONOTONICITY ------------------------------------------------------
  let lastApplied = readLastAppliedSequence(cfg)
  if selected.sequence <= lastApplied:
    return AgentOutcome(kind: aoConverged, target: cfg.target,
      sequence: selected.sequence, deploymentId: selected.deploymentId,
      message: "already converged at sequence " & $lastApplied &
        " (selected " & $selected.sequence & " is not newer)")

  # -- APPLY (strictly-higher valid sequence) ----------------------------
  let applied = deps.apply(selected)
  if not applied.ok:
    return AgentOutcome(kind: aoApplyFailed, target: cfg.target,
      sequence: selected.sequence, deploymentId: selected.deploymentId,
      message: "apply failed at sequence " & $selected.sequence & ": " &
        applied.message,
      errorCode: "apply_failed")

  # Persist only AFTER a successful apply so a failed apply never advances
  # the monotonic floor (a wrong-signer/failed manifest can't poison it).
  writeLastAppliedSequence(cfg, selected.sequence)
  return AgentOutcome(kind: aoApplied, target: cfg.target,
    sequence: selected.sequence, deploymentId: selected.deploymentId,
    message: "applied sequence " & $selected.sequence & ": " &
      applied.message)

# ---------------------------------------------------------------------------
# Allowed-signers helpers.
# ---------------------------------------------------------------------------

proc anchorsFromKeypairs*(keys: openArray[peerAuth.PublicKeyBytes]):
    peerAuth.TrustAnchors =
  ## Build an allowed-signers set from raw ECDSA-P256 public keys. Thin
  ## wrapper over ``peerAuth.newTrustAnchors`` + ``addAnchor`` so callers
  ## and tests don't reach into the peer-cache module directly.
  result = peerAuth.newTrustAnchors()
  for k in keys:
    peerAuth.addAnchor(result, k)

proc loadAllowedSigners*(path: string): peerAuth.TrustAnchors =
  ## Load the allowed-signers file (one 130-char hex ECDSA-P256 pubkey per
  ## line — the cache's trust-anchor format, reused verbatim). This is the
  ## production wiring's counterpart of the Linux agent's OpenSSH
  ## ``allowed-signers`` file.
  peerAuth.loadTrustAnchors(path)
