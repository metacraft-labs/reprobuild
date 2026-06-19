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

import std/[net, options, os, osproc, strutils]

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

# ---------------------------------------------------------------------------
# M9.O — auto-generated producer credentials (lazy local-dev path).
# ---------------------------------------------------------------------------
#
# Per M9.O the producer keypair is auto-generated on demand for local
# development scenarios. The key directory lives OUTSIDE the repo
# (``~/.config/repro/producer-keypair/`` on POSIX,
# ``%LOCALAPPDATA%\repro\producer-keypair\`` on Windows) — far away
# from anything ``git status`` will see, so there is no risk of an
# accidental commit. The repo ``.gitignore`` therefore does NOT need
# an entry for this path.
#
# RISK NOTE: if an operator explicitly sets ``REPRO_BINARY_CACHE_KEY_PATH``
# to a path INSIDE this repo (e.g. for debugging), the keypair would
# be tracked unless ``.gitignore`` is updated by hand. The defaults
# never do this, but consumers should be aware.

const
  AutoCredentialDirName = "producer-keypair"
    ## Directory name appended below the per-OS config root.
  AutoKeyFileName = "producer.key.pem"
  AutoCertFileName = "producer.cert.pem"

const
  EnvAutoCredentialDir = "REPRO_BINARY_CACHE_AUTO_CRED_DIR"
    ## Test-only override for the auto-credential directory. Production
    ## callers leave this unset and the per-OS default applies (see
    ## ``defaultAutoCredentialDir``). Tests set it to a fresh tmp dir
    ## per test so the keypair stays sandboxed in
    ## ``build/test-tmp/...`` and never touches user config state.

proc defaultAutoCredentialDir*(): string =
  ## Computes the per-OS default location of the auto-generated
  ## producer keypair. POSIX: ``~/.config/repro/producer-keypair/``;
  ## Windows: ``%LOCALAPPDATA%\repro\producer-keypair\``. Public so
  ## a CLI ``--print-publisher-config`` diagnostic can render the
  ## effective directory before any keygen actually happens.
  ##
  ## Honours the test-only ``REPRO_BINARY_CACHE_AUTO_CRED_DIR``
  ## override when set — tests use this to keep the auto-keygen path
  ## inside the build/test-tmp sandbox.
  let override = getEnv(EnvAutoCredentialDir, "")
  if override.len > 0:
    return override
  when defined(windows):
    let localAppData = getEnv("LOCALAPPDATA", "")
    if localAppData.len > 0:
      result = localAppData / "repro" / AutoCredentialDirName
    else:
      # Fallback for harnesses that strip LOCALAPPDATA from the env
      # block; mirror getConfigDir()'s sane shape.
      result = getConfigDir() / "repro" / AutoCredentialDirName
  else:
    # ``getConfigDir`` returns ``$XDG_CONFIG_HOME`` or ``~/.config/`` on
    # POSIX (Nim stdlib semantics). Append ``repro/<dirname>``.
    result = getConfigDir() / "repro" / AutoCredentialDirName

proc ensureAutoCredentialDir(dir: string) =
  ## Creates the keypair directory (incl. parents) with the most
  ## restrictive permissions we can portably express. On POSIX we
  ## ``chmod 0700`` after creation; on Windows the ACL inherited from
  ## ``%LOCALAPPDATA%`` is already user-private.
  createDir(dir)
  when not defined(windows):
    try:
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    except CatchableError:
      # Best-effort; createDir already succeeded and the parent
      # directory's perms keep prying neighbours out on a typical
      # POSIX home dir.
      discard

proc ensureAutoProducerKeypair*(dir: string;
                                keyPath, certPath: var string):
                                tuple[generated: bool, ok: bool, error: string] =
  ## Ensures a producer keypair exists at ``<dir>/producer.key.pem`` +
  ## ``<dir>/producer.cert.pem``. Returns the resolved paths via the
  ## ``var`` parameters and a tuple describing the outcome:
  ##
  ##   * ``generated`` — true when fresh keys were written; false when
  ##     a pre-existing keypair was loaded.
  ##   * ``ok`` — true on success; false on any I/O / crypto failure.
  ##   * ``error`` — populated when ``ok`` is false.
  ##
  ## Public so tests can drive the keygen path without going through
  ## the closure's env-var gating.
  keyPath = dir / AutoKeyFileName
  certPath = dir / AutoCertFileName
  try:
    ensureAutoCredentialDir(dir)
  except CatchableError as e:
    return (generated: false, ok: false,
            error: "binary-cache publish: failed to create auto-credential " &
              "directory " & dir & ": " & e.msg)
  let preExisting = fileExists(keyPath) and fileExists(certPath)
  try:
    # ``loadOrGenerateKeypair`` is idempotent: when both files exist it
    # loads + cross-checks; when either is missing it generates a fresh
    # ECDSA-P256 keypair + persists both files. Same code path the CLI's
    # ``cmdGenKey`` exercises.
    discard peerAuth.loadOrGenerateKeypair(certPath, keyPath)
  except CatchableError as e:
    return (generated: false, ok: false,
            error: "binary-cache publish: failed to load or generate " &
              "auto-producer keypair at " & dir & ": " & e.msg)
  when not defined(windows):
    # Tighten perms on the persisted files (0o600 equivalent) — same
    # treatment SSH gives ``id_ed25519``.
    for f in [keyPath, certPath]:
      try:
        setFilePermissions(f, {fpUserRead, fpUserWrite})
      except CatchableError:
        discard
  (generated: not preExisting, ok: true, error: "")

# ---------------------------------------------------------------------------
# M9.O — lazy start of the ``repro-cache`` WSL distro (Windows host only).
# ---------------------------------------------------------------------------
#
# When the host is Windows and the cache endpoint is unreachable, attempt
# to start the ``repro-cache`` WSL distro's ``repro-binary-cache.service``
# systemd unit. Soft-fail: any error here just leaves the endpoint
# unreachable + the publish call returns ``ok = false`` via the normal
# path.

const
  ReproCacheWslDistro = "repro-cache"
  ReproCacheSystemdUnit = "repro-binary-cache.service"
  EndpointProbeTimeoutMs = 750
  EndpointStartWaitTotalMs = 5_000
  EndpointStartWaitStepMs = 250

proc parseEndpointHostPort(endpoint: string): tuple[host: string, port: int] =
  ## Extracts ``host`` + ``port`` from an endpoint like
  ## ``http://localhost:7878``. Returns ``("", 0)`` on parse failure;
  ## the caller treats that as "skip the auto-start probe".
  result = ("", 0)
  var rest = endpoint
  if rest.startsWith("http://"):
    rest = rest[7 .. ^1]
  elif rest.startsWith("https://"):
    rest = rest[8 .. ^1]
  else:
    return
  # Strip path component.
  let slash = rest.find('/')
  if slash >= 0:
    rest = rest[0 ..< slash]
  let colon = rest.rfind(':')
  if colon < 0:
    # Default port 80 / 443. Local cache endpoint always carries a port
    # explicitly so this fallback shouldn't fire in practice.
    result = (host: rest, port: (if endpoint.startsWith("https://"): 443 else: 80))
    return
  let host = rest[0 ..< colon]
  let portStr = rest[colon + 1 .. ^1]
  try:
    result = (host: host, port: parseInt(portStr))
  except ValueError:
    result = ("", 0)

proc probeEndpoint(host: string; port: int; timeoutMs = EndpointProbeTimeoutMs): bool =
  ## TCP-connect probe — true iff the listener accepts within the
  ## timeout. Cheap + dependency-free (no HTTP roundtrip needed: the
  ## fact that something is listening is enough signal for the
  ## downstream HTTP POST to take it from here).
  if host.len == 0 or port <= 0:
    return false
  try:
    let sock = newSocket()
    defer: sock.close()
    sock.connect(host, Port(port), timeout = timeoutMs)
    return true
  except CatchableError:
    return false

proc tryStartReproCacheWsl(): bool {.discardable.} =
  ## Invokes ``wsl -d repro-cache --user root --exec systemctl start
  ## repro-binary-cache.service``. Returns true when the command exits
  ## 0 (best-effort signal — the caller still polls the endpoint
  ## afterwards). Soft-fails on every kind of error.
  when not defined(windows):
    return false
  else:
    try:
      let p = startProcess("wsl.exe",
        args = @["-d", ReproCacheWslDistro, "--user", "root",
                 "--exec", "systemctl", "start", ReproCacheSystemdUnit],
        options = {poStdErrToStdOut, poUsePath})
      defer: p.close()
      let code = p.waitForExit(timeout = 10_000)
      return code == 0
    except CatchableError:
      return false

proc maybeAutoStartReproCache*(endpoint: string): bool =
  ## Public driver for the auto-start hook. Returns true iff after the
  ## probe + optional start sequence the endpoint is reachable.
  ##
  ##   1. Probe the endpoint once. If reachable, return true.
  ##   2. On Windows only: invoke ``wsl ... systemctl start
  ##      repro-binary-cache.service``.
  ##   3. Poll the endpoint for up to ``EndpointStartWaitTotalMs``
  ##      milliseconds in ``EndpointStartWaitStepMs`` increments.
  ##   4. Return the final reachability.
  ##
  ## On non-Windows hosts the WSL hook is unreachable; the proc still
  ## probes the endpoint so a Linux producer pointing at a local
  ## listener gets the same reachability signal back.
  let (host, port) = parseEndpointHostPort(endpoint)
  if host.len == 0 or port <= 0:
    return false
  if probeEndpoint(host, port):
    return true
  when not defined(windows):
    return false
  else:
    discard tryStartReproCacheWsl()
    var waited = 0
    while waited < EndpointStartWaitTotalMs:
      if probeEndpoint(host, port):
        return true
      sleep(EndpointStartWaitStepMs)
      waited += EndpointStartWaitStepMs
    return probeEndpoint(host, port)

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
  ## M9.L.4-refactor Step B / M9.O. Returns a ``BinaryCachePublisher``
  ## closure ready to wire into ``BuildEngineConfig.binaryCachePublisher``.
  ##
  ## Behaviour:
  ##   * On first call, snapshots the ``REPRO_BINARY_CACHE_*`` env vars
  ##     (the captured value persists for the closure's lifetime so a
  ##     mid-build env-var flip does NOT perturb subsequent publish
  ##     calls — predictable for cache audits).
  ##   * Honours ``REPRO_CACHE_DISABLE=1`` by returning ``ok = false``
  ##     with an empty error (silent disable). M9.O extends this to
  ##     skip BOTH the auto-keygen path AND the auto-start path.
  ##   * **M9.O auto-credentials.** When the key / cert env vars are
  ##     unset OR point at files that do not exist on disk, the closure
  ##     auto-generates an ECDSA-P256 keypair under the per-OS default
  ##     directory (POSIX: ``~/.config/repro/producer-keypair/``;
  ##     Windows: ``%LOCALAPPDATA%\repro\producer-keypair\``) and uses
  ##     those files for signing. The resolved paths are cached on the
  ##     closure so subsequent invocations skip re-running
  ##     ``ensureAutoProducerKeypair``. The directory is created with
  ##     0o700 permissions on POSIX; the files with 0o600.
  ##   * **M9.O lazy WSL start.** On Windows hosts only, when the cache
  ##     endpoint is unreachable on first invocation, the closure runs
  ##     ``wsl -d repro-cache --user root --exec systemctl start
  ##     repro-binary-cache.service`` once per closure lifetime and
  ##     polls the endpoint for up to 5 s. Soft-fail throughout —
  ##     downstream ``publishInProcess`` returns the HTTP failure when
  ##     the listener still isn't up.
  ##   * Otherwise loads the keypair from disk, derives the entry-key
  ##     hex from ``req.identity``, deduces the publish prefix from
  ##     ``req.cwd + req.declaredOutputs``, and forwards to
  ##     ``publishInProcess``.
  ##
  ## The returned closure is ``{.gcsafe, closure.}`` per the engine's
  ## seam contract.
  var envCache: Option[BinaryCachePublisherEnv] = none(BinaryCachePublisherEnv)
  # M9.O — auto-credential path latches the resolved key / cert paths so
  # subsequent invocations within the same process reuse the same
  # directory without re-running ``ensureAutoProducerKeypair``.
  var autoKeyPath = ""
  var autoCertPath = ""
  var autoStartAttempted = false
  result = proc(req: BinaryCachePublishRequest):
      BinaryCachePublishResult {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      if envCache.isNone:
        envCache = some(readPublisherEnv())
      let env = envCache.get()
      if env.disabled:
        # Silent disable — no error message, no diagnostic noise.
        # M9.O preserves this gate: when the operator sets
        # ``REPRO_CACHE_DISABLE=1`` we skip BOTH the auto-keygen path
        # AND the auto-start path (no side-effects beyond returning the
        # silent miss).
        return BinaryCachePublishResult(ok: false, statusCode: 0,
          error: "", bytesUploaded: 0)
      # M9.O — resolve the effective key / cert paths.
      #
      #   * If both env vars are set AND both files exist on disk:
      #     classic env-driven path (unchanged from M9.L.4).
      #   * Otherwise: fall through to auto-credential generation under
      #     the per-OS default directory. This handles three cases
      #     uniformly:
      #       (a) env vars unset (most common — local dev),
      #       (b) env vars set but pointing at missing files,
      #       (c) env vars set + files present (env wins; auto path
      #           short-circuits).
      var keyPath = env.keyPath
      var certPath = env.certPath
      let envPathsUsable = env.keyPath.len > 0 and env.certPath.len > 0 and
        fileExists(env.keyPath) and fileExists(env.certPath)
      if not envPathsUsable:
        if autoKeyPath.len == 0 or autoCertPath.len == 0:
          let dir = defaultAutoCredentialDir()
          var resolvedKey, resolvedCert: string
          let outcome = ensureAutoProducerKeypair(dir, resolvedKey, resolvedCert)
          if not outcome.ok:
            return BinaryCachePublishResult(ok: false, statusCode: 0,
              error: outcome.error, bytesUploaded: 0)
          autoKeyPath = resolvedKey
          autoCertPath = resolvedCert
        keyPath = autoKeyPath
        certPath = autoCertPath
      var keypair: peerAuth.PeerKeypair
      try:
        if not fileExists(keyPath) or not fileExists(certPath):
          return BinaryCachePublishResult(ok: false, statusCode: 0,
            error: "binary-cache publish: keypair files missing on disk " &
              "(key=" & keyPath & ", cert=" & certPath & ")",
            bytesUploaded: 0)
        keypair = peerAuth.loadOrGenerateKeypair(certPath, keyPath)
      except CatchableError as e:
        return BinaryCachePublishResult(ok: false, statusCode: 0,
          error: "binary-cache publish: failed to load keypair " &
            "(" & keyPath & " / " & certPath & "): " & e.msg,
          bytesUploaded: 0)
      # M9.O — attempt to lazily bring up the ``repro-cache`` WSL distro
      # on Windows when the endpoint is unreachable. Soft-fail: when the
      # auto-start cannot bring the endpoint up, we still hand off to
      # ``publishInProcess`` and let the HTTP layer return the
      # connection failure through the normal soft-fail path. Only one
      # attempt per closure lifetime (latched in ``autoStartAttempted``)
      # to keep multi-action builds from racing the systemd start.
      if not autoStartAttempted:
        autoStartAttempted = true
        discard maybeAutoStartReproCache(env.endpoint)
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
