## Request-size bounds and rate limiting for a pre-authentication
## surface.
##
## ## Why this is not optional
##
## Everything the agent serves is reachable before anything has
## authenticated, because there is nothing to authenticate *to*: the
## agent holds no long-term keys, and its trustworthiness comes entirely
## from being part of a measured image. A caller that can reach the port
## can ask for a quote. So the only defences available are the shape of a
## request and how often one may be made, and both have to be enforced
## before the request is understood — a limit applied after parsing is a
## limit an unparseable request walks past.
##
## ## Two buckets, and why one is not enough
##
## A single per-client bucket is defeated by a caller with many source
## addresses. A single global bucket is defeated by one caller taking the
## whole allowance and starving everyone else. Both are charged, and both
## must admit the request:
##
##   * the **global** bucket bounds total load whatever the source
##     diversity, and is what a table of per-client state cannot be made
##     to exceed;
##   * the **per-client** bucket stops one caller consuming the global
##     allowance.
##
## The second of those only works if the per-client allowance is
## *smaller* than the global one, and that is worth stating because
## giving both buckets the same capacity is the natural thing to write
## and it makes the per-client bucket decorative: one caller drains the
## global bucket at exactly the moment it drains its own, so the second
## caller to arrive is refused globally and the per-client bucket has
## never decided anything. The defaults below therefore give a single
## client a third of the machine's burst and under half its sustained
## rate, so at least three callers can be in flight before the global
## bound is what refuses anyone.
##
## The per-client table is bounded, because an unbounded map keyed by
## something the caller chooses is itself the attack. When it is full,
## buckets *at full capacity* are evicted first: a full bucket and an
## absent one grant exactly the same thing, so dropping it loses no
## enforcement. If every tracked bucket is partially drained the new
## client is admitted on the global bucket alone — deliberately, because
## the alternative is letting an address-cycling caller lock out
## everybody else, and the global bucket is still standing behind it.
##
## ## Cost, not count
##
## A liveness probe is free; a quote is not. On a real root of trust a
## quote is a command transaction the hardware itself rate-limits, and on
## a TPM it is measured in the hundreds of milliseconds. A limiter that
## counted requests would have to be sized for health probes, and would
## then wave through as many quotes as probes. So each endpoint declares
## what it costs and the bucket is charged that much.
##
## ## Mocking
##
## None. The clock is a parameter — every entry point takes the current
## time in milliseconds — so that a test can drive refill without
## sleeping, and so the module has no ambient dependency to stub.

import std/[tables]

const
  DefaultMaxRequestLineBytes* = 8_192
    ## Request line, including the verb, the target and its query. A
    ## challenge is at most 128 bytes, so 256 hex characters; the rest is
    ## slack for a path and a query nobody has thought of yet.

  DefaultMaxHeaderBytes* = 16_384
    ## Every header line added up. Bounded in aggregate rather than per
    ## line, because a thousand short headers costs the same as one long
    ## one.

  DefaultMaxHeaderCount* = 64

  DefaultMaxBodyBytes* = 262_144
    ## Only two endpoints take a body. The larger is a provisioning
    ## request carrying one wrapped secret; a quarter of a mebibyte is
    ## generous for that and refuses anything that is really an upload.

  DefaultReadTimeoutMs* = 5_000
    ## How long one read may block. This is what makes a client that
    ## opens a connection and says nothing cost a bounded amount of time
    ## rather than a permanent one.

  DefaultConnectionDeadlineMs* = 15_000
    ## How long one connection may live in total. A client that dribbles
    ## a byte per read window would refresh the read timeout forever;
    ## this is the ceiling that does not reset.

  DefaultRateCapacity* = 120.0
    ## The machine's burst allowance, in cost units: a hundred and twenty
    ## cheap requests, or twelve quotes, arriving at once are served.

  DefaultRateRefillPerSecond* = 40.0

  DefaultPerClientCapacity* = 40.0
    ## One caller's share of it — four quotes in a burst. Deliberately a
    ## third of the machine's, for the reason in the header: a per-client
    ## bucket as large as the global one never refuses first, and so
    ## never refuses at all.

  DefaultPerClientRefillPerSecond* = 15.0

  DefaultMaxTrackedClients* = 1_024

  CostCheap* = 1
    ## Liveness, and serving a document already in memory.

  CostQuote* = 10
    ## Anything that reaches the root of trust.

type
  AgentLimits* = object
    ## The complete set of bounds. One record, so a deployment that
    ## tightens them cannot tighten half.
    maxRequestLineBytes*: int
    maxHeaderBytes*: int
    maxHeaderCount*: int
    maxBodyBytes*: int
    readTimeoutMs*: int
    connectionDeadlineMs*: int
    rateCapacity*: float
    rateRefillPerSecond*: float
    perClientCapacity*: float
    perClientRefillPerSecond*: float
    maxTrackedClients*: int

  TokenBucket = object
    tokens: float
    lastRefillMs: int64

  RateLimiter* = ref object
    ## Charged twice per request: once globally, once per client.
    capacity: float
    refillPerSecond: float
    clientCapacity: float
    clientRefillPerSecond: float
    maxTracked: int
    global: TokenBucket
    perClient: Table[string, TokenBucket]

  RateDecision* = enum
    ## Which bucket refused, so a diagnostic can say. A caller told only
    ## "too many requests" cannot tell "you are asking too fast" from
    ## "this machine is busy", and those have different remedies.
    rdAdmitted
    rdRefusedGlobal
    rdRefusedClient

proc defaultAgentLimits*(): AgentLimits =
  AgentLimits(
    maxRequestLineBytes: DefaultMaxRequestLineBytes,
    maxHeaderBytes: DefaultMaxHeaderBytes,
    maxHeaderCount: DefaultMaxHeaderCount,
    maxBodyBytes: DefaultMaxBodyBytes,
    readTimeoutMs: DefaultReadTimeoutMs,
    connectionDeadlineMs: DefaultConnectionDeadlineMs,
    rateCapacity: DefaultRateCapacity,
    rateRefillPerSecond: DefaultRateRefillPerSecond,
    perClientCapacity: DefaultPerClientCapacity,
    perClientRefillPerSecond: DefaultPerClientRefillPerSecond,
    maxTrackedClients: DefaultMaxTrackedClients)

proc validateAgentLimits*(l: AgentLimits) =
  ## Every bound must be positive. A zero or negative limit reads like
  ## "unlimited" and would be, so it is refused at configuration time
  ## rather than discovered under load.
  proc positive(name: string; v: int) =
    if v <= 0:
      raise newException(ValueError,
        "attestation-agent limit " & name & " is " & $v &
        "; every bound must be positive, because a bound of zero is not " &
        "a bound but the absence of one")
  positive("maxRequestLineBytes", l.maxRequestLineBytes)
  positive("maxHeaderBytes", l.maxHeaderBytes)
  positive("maxHeaderCount", l.maxHeaderCount)
  positive("maxBodyBytes", l.maxBodyBytes)
  positive("readTimeoutMs", l.readTimeoutMs)
  positive("connectionDeadlineMs", l.connectionDeadlineMs)
  positive("maxTrackedClients", l.maxTrackedClients)
  if l.rateCapacity <= 0.0:
    raise newException(ValueError,
      "attestation-agent limit rateCapacity is " & $l.rateCapacity &
      "; a capacity of zero admits nothing at all")
  if l.rateRefillPerSecond <= 0.0:
    raise newException(ValueError,
      "attestation-agent limit rateRefillPerSecond is " &
      $l.rateRefillPerSecond &
      "; without refill the first burst is the last traffic ever served")
  if l.perClientCapacity <= 0.0 or l.perClientRefillPerSecond <= 0.0:
    raise newException(ValueError,
      "attestation-agent per-client rate limits must be positive, got " &
      "capacity " & $l.perClientCapacity & " and refill " &
      $l.perClientRefillPerSecond)
  if l.rateCapacity < float(CostQuote) or
     l.perClientCapacity < float(CostQuote):
    raise newException(ValueError,
      "attestation-agent rate capacity is " & $l.rateCapacity &
      " globally and " & $l.perClientCapacity &
      " per client, and one of them is below the cost of a single quote (" &
      $CostQuote & "); no quote would ever be served")
  if l.perClientCapacity > l.rateCapacity:
    raise newException(ValueError,
      "attestation-agent perClientCapacity (" & $l.perClientCapacity &
      ") exceeds rateCapacity (" & $l.rateCapacity &
      "); a per-client allowance larger than the machine's can never be " &
      "the bucket that refuses, which makes it no bucket at all")
  if l.connectionDeadlineMs < l.readTimeoutMs:
    raise newException(ValueError,
      "attestation-agent connectionDeadlineMs (" & $l.connectionDeadlineMs &
      ") is below readTimeoutMs (" & $l.readTimeoutMs &
      "); the deadline would fire before a single read could complete")

proc newRateLimiter*(l: AgentLimits; nowMs: int64): RateLimiter =
  validateAgentLimits(l)
  RateLimiter(
    capacity: l.rateCapacity,
    refillPerSecond: l.rateRefillPerSecond,
    clientCapacity: l.perClientCapacity,
    clientRefillPerSecond: l.perClientRefillPerSecond,
    maxTracked: l.maxTrackedClients,
    global: TokenBucket(tokens: l.rateCapacity, lastRefillMs: nowMs),
    perClient: initTable[string, TokenBucket]())

proc refilled(b: TokenBucket; capacity, perSecond: float;
              nowMs: int64): TokenBucket =
  ## Tokens accrue with elapsed time and saturate at capacity. Time
  ## running backwards — a clock step, which happens — adds nothing
  ## rather than removing something; a limiter is not a clock and must
  ## not become one.
  let elapsedMs = nowMs - b.lastRefillMs
  var tokens = b.tokens
  if elapsedMs > 0:
    tokens = tokens + (float(elapsedMs) / 1000.0) * perSecond
    if tokens > capacity: tokens = capacity
  TokenBucket(tokens: tokens, lastRefillMs: nowMs)

proc trackedClients*(rl: RateLimiter): int =
  ## How many per-client buckets are held. Exposed so the bound on that
  ## table can be measured rather than asserted.
  rl.perClient.len

proc availableGlobalTokens*(rl: RateLimiter; nowMs: int64): float =
  refilled(rl.global, rl.capacity, rl.refillPerSecond, nowMs).tokens

proc evictOneFullBucket(rl: RateLimiter; nowMs: int64): bool =
  ## Drop a bucket that is at capacity. Such a bucket permits exactly
  ## what an absent one does, so this frees a slot without weakening a
  ## single decision.
  var victim = ""
  for client, bucket in rl.perClient:
    if refilled(bucket, rl.clientCapacity, rl.clientRefillPerSecond,
                nowMs).tokens >= rl.clientCapacity:
      victim = client
      break
  if victim.len == 0: return false
  rl.perClient.del(victim)
  true

proc charge*(rl: RateLimiter; client: string; cost: int;
             nowMs: int64): RateDecision =
  ## Charge both buckets, or neither.
  ##
  ## The global bucket is consulted first and, when it refuses, the
  ## per-client bucket is left untouched: a caller must not be charged
  ## for a request the machine did not serve.
  let c = float(cost)
  var g = refilled(rl.global, rl.capacity, rl.refillPerSecond, nowMs)
  if g.tokens < c:
    rl.global = g
    return rdRefusedGlobal

  var tracked = rl.perClient.hasKey(client)
  if not tracked and rl.perClient.len >= rl.maxTracked:
    tracked = rl.evictOneFullBucket(nowMs)
    # If nothing could be evicted the client is admitted on the global
    # bucket alone. See the module header: the alternative hands an
    # address-cycling caller a lockout of everyone else, and the global
    # bucket below is still charged either way.

  if tracked or rl.perClient.hasKey(client) or
     rl.perClient.len < rl.maxTracked:
    var b = refilled(
      rl.perClient.getOrDefault(client,
        TokenBucket(tokens: rl.clientCapacity, lastRefillMs: nowMs)),
      rl.clientCapacity, rl.clientRefillPerSecond, nowMs)
    if b.tokens < c:
      rl.perClient[client] = b
      rl.global = g
      return rdRefusedClient
    b.tokens = b.tokens - c
    rl.perClient[client] = b

  g.tokens = g.tokens - c
  rl.global = g
  rdAdmitted
