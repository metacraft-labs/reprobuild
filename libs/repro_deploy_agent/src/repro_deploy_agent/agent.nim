## Windows-Runner-Binary-Cache-Deploy M5 — the reprobuild deploy agent.
##
## A signed desired-state manifest PULL LOOP: the reprobuild-native analog
## of the Linux ``mcl-deploy-agent`` (nixos-modules
## ``packages/mcl-devops/src/mcl/commands/deploy_agent.d``). One agent tick:
##
##   1. POLL every configured manifest source. A source is an HTTP(S) URL
##      (fetched with ``std/httpclient``), a ``file://`` URL, or a plain
##      local filesystem path (both read straight off disk — the hermetic
##      test path). A 404 on an HTTP source is a soft miss (no manifest yet
##      → wait), any other fetch error is a hard, retryable failure.
##   2. DECODE each fetched manifest (the ``RDMF`` envelope).
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

import std/[algorithm, asyncdispatch, asyncfutures, httpclient, monotimes, os,
            strutils, times, uri]

when defined(ssl):
  import std/net
  import wrappers/openssl

import repro_infra/addon_diagnostics

import ./agent_mutations
import ./manifest
import ./secrets
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

# Windows-Runner-Binary-Cache-Deploy M7 (prereq b): HTTPS manifest sources.
# When built with -d:ssl (the packaged `repro` binary is, per
# apps/entrypoints.txt), the deploy-agent's default fetcher builds an OpenSSL
# context for https:// URLs, resolving the verify mode from the SAME env knobs
# the substitute client's http_pool uses so the two consumer paths behave
# identically:
#
#   * REPRO_BINARY_CACHE_TLS_INSECURE=1|true|yes → CVerifyNone (skip-verify
#     escape hatch; the manifest ECDSA-P256 signature stays the end-to-end
#     trust boundary, so this only relaxes TRANSPORT auth).
#   * else REPRO_BINARY_CACHE_CA_FILE set → CVerifyPeer against that CA (the
#     self-signed cert of the M6 HTTPS cache / behind-NetBird deployment).
#   * else CVerifyPeer against the system trust store.
#
# Plain http:// never touches this context. In a non-ssl build the context is
# nil and newHttpClient stays plain-HTTP-only (https:// then fails loud in
# std/httpclient), so this file still compiles without -d:ssl.
when defined(ssl):
  var gAgentTlsCtx: SslContext = nil
  var gAgentOpenSslInitialized = false

  proc ensureAgentOpenSslInitialized() {.gcsafe.} =
    {.cast(gcsafe).}:
      if not gAgentOpenSslInitialized:
        discard SSL_library_init()
        gAgentOpenSslInitialized = true

  proc agentTlsContext(): SslContext {.gcsafe.} =
    # The context is process-global and resolved once (the agent tick runs
    # on one thread, mirroring http_pool's cached ``gTlsCtx``); the
    # ``cast(gcsafe)`` documents that the global access is safe here.
    {.cast(gcsafe).}:
      if gAgentTlsCtx != nil:
        return gAgentTlsCtx
      ensureAgentOpenSslInitialized()
      let caFile = getEnv("REPRO_BINARY_CACHE_CA_FILE", "")
      let insecure = getEnv("REPRO_BINARY_CACHE_TLS_INSECURE", "") in
        ["1", "true", "yes"]
      if insecure:
        gAgentTlsCtx = newContext(verifyMode = CVerifyNone)
      elif caFile.len > 0:
        gAgentTlsCtx = newContext(verifyMode = CVerifyPeer, caFile = caFile)
      else:
        gAgentTlsCtx = newContext(verifyMode = CVerifyPeer)
      return gAgentTlsCtx

type
  AgentOutcomeKind* = enum
    aoWaiting          ## no manifest for this target yet (all sources missed)
    aoConverged        ## selected sequence <= last-applied; nothing to do
    aoApplied          ## a strictly-higher valid sequence was applied
    aoRejected         ## a manifest failed signature/trust verification
    aoAmbiguous        ## two manifests tie on the highest sequence
    aoSourceError      ## a source read/fetch failed (retryable)
    aoApplyFailed      ## the apply hook returned failure
    aoSecretsFailed    ## a sealed section could not be opened / materialised
    aoUnsupportedBase  ## the apply refused the host's base (ReproOS add-on
                       ## spec §7.9, ``EAddOnUnsupportedBase``): an operator
                       ## must act, a retry cannot fix it
    aoStale            ## the selected manifest is older than the maximum age
                       ## it carries (RDMF v3): a mirror may be frozen
    aoRolledBack       ## the apply failed confirmation and was reverted; the
                       ## deployment is quarantined and not retried
    aoPaused           ## an operator rolled the host back locally; the agent
                       ## does not re-converge until ``resume``

  AgentOutcome* = object
    kind*: AgentOutcomeKind
    target*: string
    sequence*: uint64          ## the selected/applied sequence (0 if none)
    deploymentId*: string
    message*: string
    errorCode*: string

  EApplyRolledBack* = object of CatchableError
    ## Raised by an apply hook whose apply was attempted, failed its
    ## confirmation (or any later step) and was reverted to the generation
    ## the host ran before. The agent quarantines the deployment
    ## (``aoRolledBack``) instead of retrying it on every tick.

  ApplyHook* = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.}
    ## May raise ``EAddOnUnsupportedBase`` (and nothing else): the one
    ## refusal the agent reports as an operator action of its own
    ## (``aoUnsupportedBase``). Every other failure is ``ok = false``.
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
    secretsKeyPath*: string
      ## Path to this target's RECIPIENT private key (`ecdsa-p256:<hex>`), used
      ## to open a v2 manifest's sealed section. Empty ⇒ this box is not
      ## configured to receive secrets, and a manifest that carries them is a
      ## hard failure rather than a silent partial apply. See `runAgentTick`.
    secretsDir*: string
      ## Directory the opened secret files are materialised under. Securing it
      ## is the profile's job (see `materialiseSecrets`).
    secretsSink*: proc(m: DeployManifest): string {.gcsafe.}
      ## When set, takes the selected manifest's sealed section INSTEAD of
      ## opening it with `secretsKeyPath` and writing it under `secretsDir`,
      ## and returns "" when it was accepted or why not (reported as
      ## `aoSecretsFailed`, nothing applied). It sees the whole manifest,
      ## so it can check the section against the profile it comes with. A
      ## ReproOS add-on host sets it: there the section is checked against
      ## the host's recipient key and the profile's declarations, staged
      ## sealed for the apply, and materialised only into a ramfs, per
      ## service, by the apply (`repro_addon/secrets_ops`).
    requireAttestations*: bool
      ## Refuse every manifest that does not carry the RDMF v3 attestation
      ## block (closure digests, ``issuedAt`` and maximum age, rollback
      ## floor): v1, v2, and a v3 envelope with the bundle alone. A ReproOS
      ## add-on agent sets it (spec §13 decision 14); the refusal is
      ## ``aoRejected`` with ``errorCode`` ``attestations_required``.

  DriftProbe* = proc(): seq[string] {.gcsafe.}
    ## Called once per tick, whatever the outcome: what changed on the host
    ## underneath the agent since the previous tick (a ReproOS add-on host:
    ## the apt hook's new events). Must not raise.

  AgentDeps* = object
    ## Test seam. ``apply`` is the apply hook. ``httpGet`` overrides the
    ## HTTP fetch (nil ⇒ the real ``std/httpclient`` path). The hermetic
    ## gates use plain-path sources so they never touch ``httpGet``.
    apply*: ApplyHook
    httpGet*: proc(url: string; timeoutMs: int):
      tuple[ok: bool; missing: bool; body: seq[byte]; error: string] {.gcsafe.}
    driftProbe*: DriftProbe
      ## nil: no drift is collected. ``runAgentTickRecorded`` calls it.
    nowUnix*: proc(): int64 {.gcsafe.}
      ## The clock the staleness check reads (seconds since the epoch);
      ## nil: the system clock. A test pins it.

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

proc safeTargetName*(target: string): string =
  ## Filesystem-safe rendering of a target name (mirrors the Linux
  ## agent's ``safeTargetName``): keep alnum/._-, replace the rest.
  ##
  ## Exported because every per-target file under ``<stateDir>/deploy-agent``
  ## must share ONE stem — the ``.seq`` file below and the tick-status record
  ## in ``tick_status.nim`` — so a second copy of this rule cannot drift.
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
# Quarantine (``aoRolledBack``) and the operator's pause (``aoPaused``).
#
# A deployment whose apply was reverted is recorded, with its sequence, in
# ``<stateDir>/deploy-agent/<safe-target>.quarantine``; the agent does not
# apply it again, and a strictly higher sequence clears the record when it
# applies. A local operator rollback writes ``<stateDir>/deploy-agent/pause``
# (``key=value`` lines: ``generation``, ``operator``, ``at``); while it
# exists every tick reports ``aoPaused`` and applies nothing.
# ---------------------------------------------------------------------------

proc quarantinePath*(cfg: AgentConfig): string =
  cfg.stateDir / "deploy-agent" / (safeTargetName(cfg.target) & ".quarantine")

proc readQuarantine*(cfg: AgentConfig):
    tuple[found: bool; sequence: uint64; deploymentId: string] =
  ## The quarantined deployment, if any. A malformed record raises: a
  ## quarantine silently dropped would re-apply a known-bad generation.
  let path = quarantinePath(cfg)
  if not fileExists(path): return
  for raw in readFile(path).splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    let sp = line.find(' ')
    if sp <= 0:
      raise newException(CatchableError,
        "corrupt quarantine record at " & path & ": " & line)
    try:
      result.sequence = parseBiggestUInt(line[0 ..< sp])
    except ValueError:
      raise newException(CatchableError,
        "corrupt quarantine record at " & path & ": " & line)
    result.deploymentId = line[sp + 1 .. ^1]
    result.found = true

proc writeQuarantine*(cfg: AgentConfig; sequence: uint64; deploymentId: string) =
  let path = quarantinePath(cfg)
  createDir(parentDir(path))
  writeFile(path, "# deployment reverted by its own apply; not retried\n" &
    $sequence & " " & deploymentId & "\n")

proc clearQuarantine*(cfg: AgentConfig) =
  let path = quarantinePath(cfg)
  if fileExists(path): removeFile(path)

proc pauseMarkerPath*(stateDir: string): string =
  stateDir / "deploy-agent" / "pause"

proc readPauseMarker*(stateDir: string):
    tuple[paused: bool; generation, operator, at: string] =
  let path = pauseMarkerPath(stateDir)
  if not (fileExists(path) or symlinkExists(path)): return
  result.paused = true
  try:
    for raw in readFile(path).splitLines():
      let eq = raw.find('=')
      if eq <= 0: continue
      let (k, v) = (raw[0 ..< eq].strip(), raw[eq + 1 .. ^1].strip())
      case k
      of "generation": result.generation = v
      of "operator": result.operator = v
      of "at": result.at = v
      else: discard
  except CatchableError:
    discard   # unreadable: still paused, which is the safe direction

proc writePauseMarker*(stateDir, generation, operator: string) =
  let path = pauseMarkerPath(stateDir)
  createDir(parentDir(path))
  writeFile(path, "generation=" & generation & "\noperator=" & operator &
    "\nat=" & now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'") & "\n")

proc clearPauseMarker*(stateDir: string): bool =
  ## Remove the marker; true when there was one.
  let path = pauseMarkerPath(stateDir)
  if fileExists(path) or symlinkExists(path):
    removeFile(path)
    return true
  false

proc staleness*(m: DeployManifest; nowUnix: int64):
    tuple[stale: bool; ageSeconds: int64] =
  ## Whether ``m`` is older than the maximum age it carries. A manifest
  ## without the attestation block makes no freshness claim and is never
  ## stale here (an agent that needs the claim requires the block).
  if not m.hasAttestations: return
  result.ageSeconds = nowUnix - int64(m.issuedAt)
  when agentMutated("rdmf-ignores-issued-at"):
    return
  result.stale = result.ageSeconds > 0 and
    uint64(result.ageSeconds) > m.maxAgeSeconds

proc attestationRefusal*(m: DeployManifest): string =
  ## Why an agent that requires the v3 attestation block refuses ``m``,
  ## or "".
  if m.formatVersion < DeployManifestFormatVersionV3:
    return "format version " & $m.formatVersion & " is refused: this agent " &
      "requires RDMF v3 with closure digests, issuedAt and a maximum age"
  if not m.hasAttestations:
    return "this v3 manifest carries no attestation block (closure " &
      "digests, issuedAt, maximum age, rollback floor), which this agent " &
      "requires"
  ""

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

proc fetchDeadlineMs*(timeoutMs: int): int =
  ## The whole-fetch deadline: four per-step timeouts, and never under a
  ## minute, so a slow but honest source on a congested LAN still completes
  ## a 32 MiB manifest at a few hundred KiB/s while a trickle does not.
  max(timeoutMs * 4, 60_000)

template awaitWithin(fut: untyped; timeoutMs: int; what: string): untyped =
  ## `waitFor` with the agent's fetch timeout applied to ONE step: the
  ## headers, then each body chunk. A source that stalls mid-body is an
  ## error, not a hang.
  block:
    let f = fut
    if timeoutMs > 0 and not waitFor withTimeout(f, timeoutMs):
      raise newException(IOError, what & " timed out after " &
        $timeoutMs & " ms")
    waitFor f

proc httpGetBounded*(url: string; timeoutMs, deadlineMs: int):
    tuple[ok: bool; missing: bool; body: seq[byte]; error: string] {.gcsafe.} =
  ## Fetch a manifest source over HTTP(S) with the body bounded by
  ## ``MaxDeployManifestBytes`` WHILE it arrives (Deploy-Agent.md
  ## §Strictness). The synchronous ``HttpClient`` cannot do that: its
  ## ``request`` has parsed the whole body into memory before it returns, so
  ## a cap checked afterwards bounds nothing. The async client hands back
  ## the response after the headers and streams the body through
  ## ``bodyStream`` as this proc polls for it; stopping at the cap and
  ## closing the client closes the connection, so what is ever held is the
  ## cap plus the chunks already in flight. ``Content-Length``, when sent,
  ## refuses an oversized body before a byte of it is read, and sizes the
  ## buffer once (`min(Content-Length, cap)`) so a body under the cap is not
  ## copied through a growing seq.
  ##
  ## Two clocks bound the time. `timeoutMs` applies to each step (the
  ## headers, every chunk), so a source that stops talking is an error. A
  ## whole-fetch deadline, `fetchDeadlineMs(timeoutMs)`, applies from the
  ## request to the last byte, so a source that keeps talking but trickles
  ## (one byte per half-second never trips a per-chunk timeout; at that
  ## rate the cap is a year away) is an error too. Both raise the same
  ## `IOError`, which the tick records as a source error and retries next
  ## tick.
  {.cast(gcsafe).}:
    let isHttps = url.toLowerAscii().startsWith("https://")
    when defined(ssl):
      var client =
        if isHttps: newAsyncHttpClient(sslContext = agentTlsContext())
        else: newAsyncHttpClient()
    else:
      if isHttps:
        return (ok: false, missing: false, body: @[],
                error: "https:// manifest source requires a build with -d:ssl; " &
                       "this binary is HTTP-only")
      var client = newAsyncHttpClient()
    let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
    try:
      let resp = awaitWithin(client.request(url, HttpGet), timeoutMs,
        "fetching " & url)
      if resp.code == Http404:
        return (ok: false, missing: true, body: @[], error: "404")
      if not resp.code.is2xx:
        return (ok: false, missing: false, body: @[],
                error: "HTTP " & $resp.code)
      var declared = 0
      if resp.headers.hasKey("Content-Length"):
        try:
          declared = parseInt(resp.headers["Content-Length"])
        except ValueError:
          return (ok: false, missing: false, body: @[],
                  error: "unparseable Content-Length header")
        if declared > MaxDeployManifestBytes:
          return (ok: false, missing: false, body: @[],
                  error: "manifest body of " & $declared & " bytes exceeds " &
                    "the " & $MaxDeployManifestBytes & "-byte cap")
      var bytes = newSeqOfCap[byte](
        if declared > 0: min(declared, MaxDeployManifestBytes) else: 0)
      while true:
        let left = deadline - getMonoTime()
        if left <= DurationZero:
          raise newException(IOError, "reading the manifest body from " & url &
            " exceeded the " & $deadlineMs & " ms deadline " &
            "for the whole fetch (" & $bytes.len & " bytes received)")
        # The per-chunk wait is clamped to what is left of the deadline, and
        # a wait that ends because the deadline did is reported as the
        # deadline, not as a chunk timeout.
        let leftMs = int(left.inMilliseconds) + 1
        let stepMs = if timeoutMs > 0: min(timeoutMs, leftMs) else: leftMs
        let (more, chunk) =
          try:
            awaitWithin(resp.bodyStream.read(), stepMs,
              "reading the manifest body from " & url)
          except IOError as e:
            if stepMs == leftMs:
              raise newException(IOError, "reading the manifest body from " &
                url & " exceeded the " & $deadlineMs & " ms deadline for " &
                "the whole fetch (" & $bytes.len & " bytes received)")
            raise e
        if not more: break
        if bytes.len + chunk.len > MaxDeployManifestBytes:
          return (ok: false, missing: false, body: @[],
                  error: "manifest body exceeds the " &
                    $MaxDeployManifestBytes & "-byte cap")
        let at = bytes.len
        bytes.setLen(at + chunk.len)
        for i, ch in chunk:
          bytes[at + i] = byte(ch)
      return (ok: true, missing: false, body: bytes, error: "")
    except CatchableError as e:
      return (ok: false, missing: false, body: @[], error: e.msg)
    finally:
      try: client.close() except CatchableError: discard

proc defaultHttpGet*(url: string; timeoutMs: int):
    tuple[ok: bool; missing: bool; body: seq[byte]; error: string] {.gcsafe.} =
  ## The production fetch: `httpGetBounded` under the agent's whole-fetch
  ## deadline. The deadline is a parameter of the bounded form so a test
  ## can measure a trickling source in seconds rather than a minute.
  httpGetBounded(url, timeoutMs, fetchDeadlineMs(timeoutMs))

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

  # -- FORMAT (an agent that requires the v3 attestation block) ----------
  if cfg.requireAttestations:
    let refusal = attestationRefusal(selected)
    if refusal.len > 0:
      return AgentOutcome(kind: aoRejected, target: cfg.target,
        sequence: selected.sequence, deploymentId: selected.deploymentId,
        message: "manifest REJECTED: " & refusal,
        errorCode: "attestations_required")

  # -- FRESHNESS (RDMF v3) -----------------------------------------------
  # Before monotonicity on purpose: a frozen mirror serves exactly the
  # sequence already applied, which would otherwise read as converged.
  let nowSec = if deps.nowUnix != nil: deps.nowUnix() else: getTime().toUnix()
  let age = staleness(selected, nowSec)
  if age.stale:
    return AgentOutcome(kind: aoStale, target: cfg.target,
      sequence: selected.sequence, deploymentId: selected.deploymentId,
      message: "manifest at sequence " & $selected.sequence & " was issued " &
        $age.ageSeconds & " s ago, past its maximum age of " &
        $selected.maxAgeSeconds & " s: the source may be frozen",
      errorCode: "stale_manifest")

  # -- PAUSE (a local operator rollback, spec §9.3 of the add-on) --------
  let pause = readPauseMarker(cfg.stateDir)
  if pause.paused:
    return AgentOutcome(kind: aoPaused, target: cfg.target,
      sequence: selected.sequence, deploymentId: selected.deploymentId,
      message: "paused by a local rollback to generation " &
        pause.generation & " (operator " & pause.operator & ", " & pause.at &
        "); `repro system addon resume` lets the agent converge again",
      errorCode: "paused")

  # -- MONOTONICITY ------------------------------------------------------
  let lastApplied = readLastAppliedSequence(cfg)
  if selected.sequence <= lastApplied:
    return AgentOutcome(kind: aoConverged, target: cfg.target,
      sequence: selected.sequence, deploymentId: selected.deploymentId,
      message: "already converged at sequence " & $lastApplied &
        " (selected " & $selected.sequence & " is not newer)")

  # -- QUARANTINE --------------------------------------------------------
  # A reverted deployment is not retried: each retry would take the
  # service down for the confirmation timeout again. Only a strictly
  # higher sequence moves on (and clears the record when it applies).
  let q = readQuarantine(cfg)
  if q.found and selected.sequence <= q.sequence:
    return AgentOutcome(kind: aoRolledBack, target: cfg.target,
      sequence: selected.sequence, deploymentId: selected.deploymentId,
      message: "deployment " & q.deploymentId & " at sequence " &
        $q.sequence & " was reverted and is quarantined; publish a higher " &
        "sequence to move on",
      errorCode: "quarantined")

  # -- SECRETS (before the apply, because the apply consumes them) -------
  #
  # Ordering is load-bearing. `register-runner.ps1` reads the registration
  # token during the apply, so the token has to be on disk before the apply
  # starts, not after it. Equally, a failure here must NOT fall through to the
  # apply: converging desired state that depends on a secret which never
  # arrived produces a box that looks applied and cannot run a job -- the exact
  # shape of failure this campaign keeps rediscovering.
  if selected.hasSecrets and cfg.secretsSink != nil:
    let refused = cfg.secretsSink(selected)
    if refused.len > 0:
      return AgentOutcome(kind: aoSecretsFailed, target: cfg.target,
        sequence: selected.sequence, deploymentId: selected.deploymentId,
        message: "sealed secrets were not accepted: " & refused,
        errorCode: "secrets_failed")
  elif selected.hasSecrets:
    if cfg.secretsKeyPath.len == 0 or cfg.secretsDir.len == 0:
      return AgentOutcome(kind: aoSecretsFailed, target: cfg.target,
        sequence: selected.sequence, deploymentId: selected.deploymentId,
        message: "manifest carries a sealed secrets section but this agent " &
          "has no --secrets-key/--secrets-dir configured; refusing to apply " &
          "desired state whose secrets would be missing",
        errorCode: "secrets_not_configured")
    try:
      let recipientKey = peerAuth.loadPrivateKeyFile(cfg.secretsKeyPath)
      let opened = openSecrets(recipientKey, selected.target, selected.secrets)
      discard materialiseSecrets(opened, cfg.secretsDir)
    except CatchableError as e:
      return AgentOutcome(kind: aoSecretsFailed, target: cfg.target,
        sequence: selected.sequence, deploymentId: selected.deploymentId,
        message: "sealed secrets could not be opened: " & e.msg,
        errorCode: "secrets_failed")

  # -- APPLY (strictly-higher valid sequence) ----------------------------
  # An add-on host whose base left the supported matrix refuses every apply
  # with the typed ``EAddOnUnsupportedBase`` (add-on spec §7.9), which an
  # apply hook lets through rather than folding it into a message: an
  # operator must act, a retry cannot fix it. The sequence is not recorded,
  # so the same manifest applies once the base is fixed.
  var applied: tuple[ok: bool; message: string]
  try:
    applied = deps.apply(selected)
  except EAddOnUnsupportedBase as e:
    return AgentOutcome(kind: aoUnsupportedBase, target: cfg.target,
      sequence: selected.sequence, deploymentId: selected.deploymentId,
      message: "the host's base is outside the supported matrix at " &
        "sequence " & $selected.sequence & ": " & e.msg,
      errorCode: "unsupported_base")
  except EApplyRolledBack as e:
    writeQuarantine(cfg, selected.sequence, selected.deploymentId)
    return AgentOutcome(kind: aoRolledBack, target: cfg.target,
      sequence: selected.sequence, deploymentId: selected.deploymentId,
      message: "apply of sequence " & $selected.sequence & " was reverted " &
        "and the deployment is quarantined: " & e.msg,
      errorCode: "rolled_back")
  if not applied.ok:
    return AgentOutcome(kind: aoApplyFailed, target: cfg.target,
      sequence: selected.sequence, deploymentId: selected.deploymentId,
      message: "apply failed at sequence " & $selected.sequence & ": " &
        applied.message,
      errorCode: "apply_failed")

  # Persist only AFTER a successful apply so a failed apply never advances
  # the monotonic floor (a wrong-signer/failed manifest can't poison it).
  writeLastAppliedSequence(cfg, selected.sequence)
  clearQuarantine(cfg)
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
