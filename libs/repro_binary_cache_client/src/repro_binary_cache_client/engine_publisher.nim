## M9.L.4-refactor Step B — producer-side ``BinaryCachePublisher``
## closure factory.
##
## The engine exposes a ``BinaryCachePublisher`` seam:
##
## ```nim
## type BinaryCachePublisher* = proc(req: BinaryCachePublishRequest):
##   BinaryCachePublishResult {.gcsafe, closure.}
## ```
##
## A ``nil`` field keeps the engine pure-local — the publish hook is a
## no-op even when the action carries ``publishToBinaryCache = true``.
## When the producer-side build wants binary-cache publishing, it wires
## a non-nil closure into ``BuildEngineConfig.binaryCachePublisher``.
## ``mkBinaryCachePublisher`` is the off-the-shelf factory for that
## closure: it reads the ``REPRO_BINARY_CACHE_*`` env vars on first
## call, builds a ``PublishInProcessRequest`` from each engine
## ``BinaryCachePublishRequest`` the engine hands off, and forwards to
## ``publishInProcess``.
##
## ## Honest deferrals
##
##   * **Wiring into ``repro build``.** This module only provides the
##     closure factory; the actual ``BuildEngineConfig`` assembly inside
##     ``apps/repro/src/repro.nim`` (or the CLI driver that owns the
##     config) is a follow-up Step C milestone. Step B leaves it to the
##     caller to wire the factory in.
##   * **Prefix deduction.** The engine's
##     ``BinaryCachePublishRequest`` carries ``cwd`` + ``declaredOutputs``.
##     For the from-source conventions (the only callers in M9.L.4),
##     the install action's stamp output lives under ``<projectRoot>/.repro/
##     build/from-source-<convention>/staging/`` and the stage-copy
##     outputs land under ``<projectRoot>/.repro/output/<member>/<member>``.
##     The publisher defaults to packing the staging tree (parent of
##     the first declared output's directory). A follow-up milestone
##     can lift a dedicated ``publishPrefix`` field onto
##     ``BuildActionDef`` (and through the engine's
##     ``BinaryCachePublishRequest``) so the convention can express the
##     prefix declaratively rather than the closure deducing it.

import std/[options, os, strutils]

import ./cache_key
import ./in_process
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_build_engine

type
  BinaryCachePublisherEnv* = object
    ## Snapshot of the ``REPRO_BINARY_CACHE_*`` env vars the factory
    ## consults. Exposed as a value type so callers (e.g. a CLI
    ## ``--print-publisher-config`` diagnostic) can inspect the
    ## effective configuration without re-reading the env.
    endpoint*: string
    keyPath*: string
    certPath*: string
    disabled*: bool

const
  EnvEndpoint = "REPRO_BINARY_CACHE_URL"
    ## Base URL for the binary cache server (``/publish`` is appended
    ## by ``publishInProcess``). Defaults to ``http://localhost:7878``
    ## when unset — matches the binary-cache server's default bind.
  EnvKeyPath = "REPRO_BINARY_CACHE_KEY_PATH"
    ## Path to the producer's ECDSA-P256 signing key file. When unset,
    ## the closure returns ``ok = false`` with a structured warning
    ## (the engine logs into stats but does NOT abort the build —
    ## soft-fail by design).
  EnvCertPath = "REPRO_BINARY_CACHE_CERT_PATH"
    ## Path to the producer's matching public-key file (the binary
    ## cache server's ``/publish`` route verifies the manifest
    ## signature against this). Same soft-fail behaviour as
    ## ``EnvKeyPath``.
  EnvDisable = "REPRO_CACHE_DISABLE"
    ## When set to ``"1"`` (or any non-empty value), the closure
    ## returns ``ok = false`` silently — no warning, no env-var
    ## probing. Matches the same env-var the in-process substitution
    ## path honours so a build wrapper that disables substitution also
    ## disables publishing without further wiring.

  DefaultEndpoint = "http://localhost:7878"

proc readPublisherEnv*(): BinaryCachePublisherEnv =
  ## Snapshot the env vars. Public so a CLI driver can render the
  ## effective configuration for diagnostics. The snapshot is
  ## intentionally taken at every call site — wrap in a closure-captured
  ## ``let`` if you want first-call latching.
  result.endpoint = getEnv(EnvEndpoint, DefaultEndpoint)
  result.keyPath = getEnv(EnvKeyPath, "")
  result.certPath = getEnv(EnvCertPath, "")
  result.disabled = getEnv(EnvDisable, "").len > 0

proc deducePublishPrefix(req: BinaryCachePublishRequest): string =
  ## M9.L.4-refactor Step B prefix-deduction heuristic. The from-source
  ## conventions don't (yet) carry a dedicated ``publishPrefix`` field
  ## on the ``BuildActionDef`` — the closure infers it from ``cwd``
  ## (the recipe's project root) + ``declaredOutputs``.
  ##
  ## Rules:
  ##   1. If the action has no declared outputs, fall back to ``cwd``.
  ##   2. If the first declared output is a directory, pack it.
  ##   3. Otherwise treat the first declared output as a single file
  ##      prefix (``publishInProcess`` handles single-file prefixes via
  ##      ``packSingleFilePrefix``).
  if req.declaredOutputs.len == 0:
    return req.cwd
  let first = req.declaredOutputs[0]
  if dirExists(first):
    return first
  first

proc mkBinaryCachePublisher*(): BinaryCachePublisher =
  ## M9.L.4-refactor Step B. Returns a ``BinaryCachePublisher`` closure
  ## ready to wire into ``BuildEngineConfig.binaryCachePublisher``.
  ##
  ## Behaviour:
  ##   * On first call, snapshots the ``REPRO_BINARY_CACHE_*`` env vars
  ##     (the captured value persists for the closure's lifetime so a
  ##     mid-build env-var flip does NOT perturb subsequent publish
  ##     calls — predictable for cache audits).
  ##   * Honours ``REPRO_CACHE_DISABLE=1`` by returning ``ok = false``
  ##     with an empty error (silent disable).
  ##   * When the key / cert env vars are unset: returns ``ok = false``
  ##     with a structured warning so the engine's stats counter
  ##     captures the miss. The build keeps succeeding (soft-fail per
  ##     spec).
  ##   * Otherwise loads the keypair from disk, derives the entry-key
  ##     hex from ``req.identity``, deduces the publish prefix from
  ##     ``req.cwd + req.declaredOutputs``, and forwards to
  ##     ``publishInProcess``.
  ##
  ## The returned closure is ``{.gcsafe, closure.}`` per the engine's
  ## seam contract.
  ##
  ## Step C wiring TODO: the actual ``BuildEngineConfig`` assembly
  ## inside ``apps/repro/src/repro.nim`` (or wherever the CLI driver
  ## owns the config) calls this factory and assigns the result onto
  ## ``cfg.binaryCachePublisher``. Until that wiring lands the engine
  ## continues to leave the field ``nil`` and the hook stays a no-op.
  var envCache: Option[BinaryCachePublisherEnv] = none(BinaryCachePublisherEnv)
  result = proc(req: BinaryCachePublishRequest):
      BinaryCachePublishResult {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      if envCache.isNone:
        envCache = some(readPublisherEnv())
      let env = envCache.get()
      if env.disabled:
        # Silent disable — no error message, no diagnostic noise.
        return BinaryCachePublishResult(ok: false, statusCode: 0,
          error: "", bytesUploaded: 0)
      if env.keyPath.len == 0 or env.certPath.len == 0:
        return BinaryCachePublishResult(ok: false, statusCode: 0,
          error: "binary-cache publish: " & EnvKeyPath & " and " &
            EnvCertPath & " must both be set to publish; got keyPath=" &
            (if env.keyPath.len > 0: "<set>" else: "<unset>") &
            ", certPath=" &
            (if env.certPath.len > 0: "<set>" else: "<unset>"),
          bytesUploaded: 0)
      var keypair: peerAuth.PeerKeypair
      try:
        # ``loadOrGenerateKeypair`` is the same entry point the CLI's
        # ``loadProducerKeypair`` uses. Both files MUST exist on disk;
        # we already gated on the env-var presence above, but the
        # producer keys are normally generated by the operator out of
        # band (the CLI's first-run generate path is intentional but
        # not appropriate for an unattended publisher closure).
        if not fileExists(env.keyPath) or not fileExists(env.certPath):
          return BinaryCachePublishResult(ok: false, statusCode: 0,
            error: "binary-cache publish: " & EnvKeyPath & "=" &
              env.keyPath & " or " & EnvCertPath & "=" & env.certPath &
              " does not exist on disk",
            bytesUploaded: 0)
        keypair = peerAuth.loadOrGenerateKeypair(env.certPath, env.keyPath)
      except CatchableError as e:
        return BinaryCachePublishResult(ok: false, statusCode: 0,
          error: "binary-cache publish: failed to load keypair " &
            "(" & env.keyPath & " / " & env.certPath & "): " & e.msg,
          bytesUploaded: 0)
      let prefixDir = deducePublishPrefix(req)
      let entryKeyHex = deriveCacheEntryKeyHex(req.identity)
      let pubReq = PublishInProcessRequest(
        entryKeyHex: entryKeyHex,
        prefixDir: prefixDir,
        identity: req.identity,
        endpoint: env.endpoint,
        keypair: keypair)
      let pubRes = publishInProcess(pubReq)
      BinaryCachePublishResult(
        ok: pubRes.ok,
        statusCode: pubRes.statusCode,
        error: pubRes.error,
        bytesUploaded: pubRes.bytesUploaded)
