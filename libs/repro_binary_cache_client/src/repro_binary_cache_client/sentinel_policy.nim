## ReproOS-Generations-And-Foreign-Packages A4 P2 — client-side
## sentinel policy.
##
## Implements the wait/parallel/error policies described in the
## campaign spec § "A4 P2". When a substituter starts work on an
## entry-key:
##
##   1. Probe ``GET /sentinel/<key>`` against the upstream cache.
##   2. If the entry is NOT claimed (HTTP 404): claim the sentinel
##      via ``POST /sentinel/<key>`` with the local producer id, then
##      proceed to fetch/build under the claim. Release via
##      ``DELETE /sentinel/<key>`` (or rely on publish auto-release)
##      when done.
##   3. If the entry IS claimed (HTTP 200) by a different producer:
##      consult the configured policy.
##        * ``spWait`` (default): poll once per second until the
##          sentinel is released (404) OR the TTL expires; then
##          re-query the manifest endpoint (we expect a cache HIT).
##        * ``spParallel``: ignore the sentinel and start the
##          substitute concurrently with the producer. Useful when the
##          local build cost is less than the expected wait.
##        * ``spError``: return immediately with an error so the
##          caller can decide what to do.
##
## The wait timeout is ``2 * sentinel-TTL`` by default — the local
## producer's TTL is the upper bound on how long any single producer
## can hold an entry, so doubling it guarantees we observe at least
## one full release/expiry cycle even if the producer immediately
## refreshes on the boundary. On timeout the policy degrades to
## ``spParallel`` behaviour so the caller still makes progress.
##
## ## Producer id convention
##
## Tests pass an explicit producer name. Production callers derive it
## as ``<hostname>:<pid>`` so two builds on the same machine still
## get distinct ids (the build engine forks worker processes; each
## worker is its own sentinel-holder).

import std/[nativesockets, net, os, osproc, strutils, times]

import ./http_pool

type
  SentinelPolicy* = enum
    spWait = "wait"           ## Poll until released; the default.
    spParallel = "parallel"   ## Ignore sentinel; race with producer.
    spError = "error"         ## Surface a structured error.

  SentinelDecision* = enum
    sdGoFetch          ## No sentinel; claim it and proceed.
    sdWaitedAndReady   ## Other producer published; we should now hit.
    sdRaceProducer     ## Caller should fetch in parallel.
    sdErrorClaimed     ## Caller should treat as failure.

  SentinelState* = object
    held*: bool
    producer*: string
    remainingSeconds*: int64

  SentinelPolicyConfig* = object
    policy*: SentinelPolicy
    pollIntervalMs*: int        ## Default 1000.
    timeoutMs*: int             ## Default 2 * TTL inferred from probe.
    claimTtlSeconds*: uint32    ## Default 300s.
    producerId*: string         ## Identity sent in X-Repro-Producer.

  SentinelError* = object of CatchableError

const
  SentinelHeaderProducer = "X-Repro-Producer"
  SentinelHeaderTtl = "X-Repro-Sentinel-TTL"
  DefaultPollIntervalMs* = 1000
  DefaultClaimTtl* = 300'u32

proc defaultProducerId*(): string =
  ## ``<hostname>:<pid>``. Hostname falls back to ``client`` when the
  ## OS lookup fails (e.g. inside a chroot without `gethostname`).
  let host =
    try:
      let n = getHostname()
      if n.len == 0: "client" else: n
    except CatchableError:
      "client"
  result = host & ":" & $getCurrentProcessId()

proc defaultSentinelPolicy*(producerId = ""): SentinelPolicyConfig =
  SentinelPolicyConfig(
    policy: spWait,
    pollIntervalMs: DefaultPollIntervalMs,
    timeoutMs: 0,
    claimTtlSeconds: DefaultClaimTtl,
    producerId:
      if producerId.len > 0: producerId else: defaultProducerId())

# ---------------------------------------------------------------------------
# Low-level HTTP shims — purpose-built mini-clients rather than reusing
# ``streamGet``: the sentinel endpoints return tiny payloads (one
# integer or a single header line) so the overhead of the streaming
# path isn't justified.
# ---------------------------------------------------------------------------

proc rawHttpRequest(target: ParsedUrl;
                    httpMethod: string;
                    extraHeaders: seq[(string, string)] = @[];
                    body = "";
                    timeoutMs = 10_000):
                      tuple[statusCode: int;
                            headers: seq[(string, string)];
                            body: string] =
  ## Hand-rolled request/response cycle for the sentinel mini-API.
  ## Returns a tuple of (status, headers, body). No keep-alive
  ## bookkeeping — each call opens + closes a socket. The sentinel
  ## endpoints fire once per build (not on the payload hot path) so
  ## the connection cost is negligible.
  let sock = newSocket()
  defer:
    try: sock.close() except CatchableError: discard
  try:
    sock.connect(target.host, target.port)
  except OSError as e:
    raise newException(SentinelError,
      "connect to " & target.host & ":" & $int(target.port) & " failed: " & e.msg)
  var req = httpMethod & " " & target.path & " HTTP/1.1\r\n" &
            "Host: " & target.host
  if int(target.port) != (if target.secure: 443 else: 80):
    req.add(":" & $int(target.port))
  req.add("\r\nUser-Agent: repro-binary-cache-client/sentinel\r\n" &
          "Accept: */*\r\n" &
          "Connection: close\r\n" &
          "Content-Length: " & $body.len & "\r\n")
  for (n, v) in extraHeaders:
    req.add(n & ": " & v & "\r\n")
  req.add("\r\n")
  if body.len > 0:
    req.add(body)
  try:
    sock.send(req)
  except OSError as e:
    raise newException(SentinelError, "send failed: " & e.msg)
  # ---- Read response ----
  # Read until we observe the headers, then drain Content-Length
  # bytes (or until EOF).
  var headBuf = ""
  while true:
    var c: char
    let n =
      try: sock.recv(addr c, 1, timeout = timeoutMs)
      except TimeoutError: 0
      except OSError as e:
        raise newException(SentinelError, "recv failed: " & e.msg)
    if n <= 0:
      break
    headBuf.add(c)
    if headBuf.len >= 4 and
       headBuf[^4] == '\r' and headBuf[^3] == '\n' and
       headBuf[^2] == '\r' and headBuf[^1] == '\n':
      break
    if headBuf.len > 65536:
      raise newException(SentinelError, "headers exceed 64 KiB")
  if headBuf.len == 0:
    raise newException(SentinelError, "empty response")
  let lines = headBuf.split("\r\n")
  if lines.len == 0 or not lines[0].startsWith("HTTP/"):
    raise newException(SentinelError, "malformed status line")
  let firstSpace = lines[0].find(' ')
  var code = 0
  if firstSpace > 0:
    try: code = parseInt(lines[0][firstSpace + 1 ..< lines[0].len].split(' ')[0])
    except CatchableError: code = 0
  result.statusCode = code
  result.headers = @[]
  var clen: int64 = -1
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.len == 0:
      continue
    let colon = line.find(':')
    if colon < 0:
      continue
    let name = line[0 ..< colon].strip().toLowerAscii()
    let value = line[colon + 1 .. ^1].strip()
    result.headers.add((name, value))
    if name == "content-length":
      try: clen = parseBiggestInt(value) except CatchableError: discard
  # ---- Body ----
  if clen >= 0:
    result.body = newString(clen)
    var got = 0'i64
    while got < clen:
      var n = 0
      try:
        n = sock.recv(result.body[int(got)].addr, int(clen - got),
                      timeout = timeoutMs)
      except TimeoutError:
        break
      except OSError:
        break
      if n <= 0:
        break
      got += int64(n)
    if got < clen:
      result.body.setLen(int(got))
  else:
    # No Content-Length: read until close.
    var buf = newString(4096)
    while true:
      var n = 0
      try:
        n = sock.recv(buf[0].addr, buf.len, timeout = timeoutMs)
      except TimeoutError:
        break
      except OSError:
        break
      if n <= 0:
        break
      result.body.add(buf[0 ..< n])

proc headerValueLower(headers: seq[(string, string)]; name: string): string =
  let lname = name.toLowerAscii()
  for (k, v) in headers:
    if k == lname:
      return v
  return ""

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc querySentinel*(baseUrl, entryKeyHex: string;
                    timeoutMs = 10_000): SentinelState =
  ## GET /sentinel/<key>. Returns ``held=false`` on 404, ``held=true``
  ## with the producer id + TTL remaining on 200.
  let target = parseTarget(baseUrl & "/sentinel/" & entryKeyHex)
  let resp = rawHttpRequest(target, "GET", timeoutMs = timeoutMs)
  if resp.statusCode == 404:
    return SentinelState(held: false, producer: "", remainingSeconds: 0)
  if resp.statusCode != 200:
    raise newException(SentinelError,
      "unexpected GET /sentinel status " & $resp.statusCode)
  var st = SentinelState(held: true)
  st.producer = headerValueLower(resp.headers, "x-repro-sentinel-producer")
  let remainRaw = headerValueLower(resp.headers, "x-repro-sentinel-ttl-remaining")
  if remainRaw.len > 0:
    try: st.remainingSeconds = parseBiggestInt(remainRaw) except CatchableError: discard
  else:
    let body = resp.body.strip()
    if body.len > 0:
      try: st.remainingSeconds = parseBiggestInt(body) except CatchableError: discard
  return st

proc claimSentinel*(baseUrl, entryKeyHex, producerId: string;
                    ttlSeconds: uint32 = DefaultClaimTtl;
                    timeoutMs = 10_000):
                      tuple[claimed: bool; statusCode: int] =
  ## POST /sentinel/<key>. Returns ``claimed=true`` on 201 (or 200 for
  ## a same-producer refresh — the client treats both as success), and
  ## ``claimed=false`` on 409 (another producer holds the entry).
  let target = parseTarget(baseUrl & "/sentinel/" & entryKeyHex)
  let resp = rawHttpRequest(target, "POST",
    extraHeaders = @[
      (SentinelHeaderProducer, producerId),
      (SentinelHeaderTtl, $ttlSeconds)],
    timeoutMs = timeoutMs)
  case resp.statusCode
  of 200, 201:
    return (true, resp.statusCode)
  of 409:
    return (false, resp.statusCode)
  else:
    raise newException(SentinelError,
      "unexpected POST /sentinel status " & $resp.statusCode)

proc releaseSentinel*(baseUrl, entryKeyHex: string;
                      timeoutMs = 10_000) =
  ## DELETE /sentinel/<key>. Idempotent. Errors are best-effort — a
  ## failed release falls back on the server's sweeper to evict.
  let target = parseTarget(baseUrl & "/sentinel/" & entryKeyHex)
  try:
    discard rawHttpRequest(target, "DELETE", timeoutMs = timeoutMs)
  except SentinelError:
    discard

# ---------------------------------------------------------------------------
# Policy entry point.
# ---------------------------------------------------------------------------

proc waitUntilReleased*(baseUrl, entryKeyHex: string;
                       pollIntervalMs, timeoutMs: int;
                       initialTtl: int64): bool =
  ## Polls ``GET /sentinel/<key>`` every ``pollIntervalMs`` until the
  ## server returns 404 OR ``timeoutMs`` is hit. Returns ``true`` on a
  ## clean release, ``false`` on timeout. ``initialTtl`` is the
  ## already-probed remaining-TTL when ``timeoutMs`` is 0 — we use
  ## ``2 * initialTtl * 1000`` as a sensible default.
  let effectiveTimeoutMs =
    if timeoutMs > 0: timeoutMs
    else: max(2_000, int(initialTtl) * 2 * 1000)
  let deadline = epochTime() + float(effectiveTimeoutMs) / 1000.0
  while epochTime() < deadline:
    let state =
      try: querySentinel(baseUrl, entryKeyHex)
      except SentinelError:
        return false
    if not state.held:
      return true
    let waitMs = max(100, pollIntervalMs)
    sleep(waitMs)
  return false

proc decideAndClaim*(cfg: SentinelPolicyConfig;
                     baseUrl, entryKeyHex: string):
                       tuple[decision: SentinelDecision; claimed: bool;
                             state: SentinelState] =
  ## Single entry point a substituter calls before fetching. Issues
  ## the probe; if free, tries to claim; if held, applies the policy.
  ## Returns:
  ##   * ``sdGoFetch``       — caller should fetch, holds the claim.
  ##   * ``sdWaitedAndReady`` — producer released; caller should fetch
  ##                            (cache HIT expected).
  ##   * ``sdRaceProducer``   — caller should fetch in parallel; does
  ##                            NOT hold a claim.
  ##   * ``sdErrorClaimed``   — caller should treat as an error.
  let probe =
    try: querySentinel(baseUrl, entryKeyHex)
    except SentinelError as e:
      raise newException(SentinelError,
        "sentinel probe failed: " & e.msg)
  if not probe.held:
    let claim = claimSentinel(baseUrl, entryKeyHex, cfg.producerId,
                              cfg.claimTtlSeconds)
    if claim.claimed:
      return (sdGoFetch, true, probe)
    else:
      # Lost the race to another producer between probe + claim. Apply
      # the policy as if the probe had returned held.
      let restate =
        try: querySentinel(baseUrl, entryKeyHex)
        except SentinelError: SentinelState(held: false)
      case cfg.policy
      of spWait:
        let released = waitUntilReleased(baseUrl, entryKeyHex,
                                          cfg.pollIntervalMs, cfg.timeoutMs,
                                          restate.remainingSeconds)
        if released:
          return (sdWaitedAndReady, false, restate)
        else:
          return (sdRaceProducer, false, restate)
      of spParallel:
        return (sdRaceProducer, false, restate)
      of spError:
        return (sdErrorClaimed, false, restate)
  if probe.producer == cfg.producerId:
    # We already hold it (e.g. a retry). Refresh the TTL.
    discard claimSentinel(baseUrl, entryKeyHex, cfg.producerId,
                          cfg.claimTtlSeconds)
    return (sdGoFetch, true, probe)
  case cfg.policy
  of spWait:
    let released = waitUntilReleased(baseUrl, entryKeyHex,
                                      cfg.pollIntervalMs, cfg.timeoutMs,
                                      probe.remainingSeconds)
    if released:
      return (sdWaitedAndReady, false, probe)
    else:
      return (sdRaceProducer, false, probe)
  of spParallel:
    return (sdRaceProducer, false, probe)
  of spError:
    return (sdErrorClaimed, false, probe)
