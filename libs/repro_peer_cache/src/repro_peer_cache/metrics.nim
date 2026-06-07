## Peer-cache observability — Peer-Cache-Scale M4.
##
## Prometheus-format metrics scrape endpoint + structured JSON debug
## endpoint. Counters, gauges, and a simple bucketed latency histogram
## are shared by reference between the live `PeerCacheServer` /
## `PeerCacheClient` and an `asynchttpserver`-based HTTP listener.
##
## The metric names below match `Peer-Cache-Scale.md`
## §"Connection lifecycle + observability". Counters are monotone
## `uint64`s mutated in place; gauges are `int` (allowed to go up or
## down). Histogram buckets carry a `Le` (less-than-or-equal) cap in
## milliseconds; the last bucket is `+Inf`.

import std/[asyncdispatch, asynchttpserver, strformat, strutils, tables, times]

import ./registry
import ./types

export asynchttpserver

const
  PrometheusContentType* = "text/plain; version=0.0.4"
    ## Standard exposition-format `Content-Type` per Prometheus 0.0.4.
  JsonContentType* = "application/json"

  FetchLatencyBucketsMs*: array[8, int] = [1, 5, 25, 100, 250, 500, 1_000, 0]
    ## Histogram cap per bucket in milliseconds. The trailing `0` is a
    ## sentinel for `+Inf` — `renderPrometheus` emits the literal `+Inf`
    ## label for the last bucket.

type
  PeerCacheMetrics* = ref object
    ## Shared observability shell. Held by `PeerCacheServer` /
    ## `PeerCacheClient` so increments at protocol-event sites are
    ## visible to the HTTP scrape endpoint without a copy.

    # ---- counters ----
    fetchRequestsTotal*: uint64
      ## Total `mkFetchRequest` frames the server has answered.
    fetchHitsLocal*: uint64
      ## Server-side: blob was present in the injected local store
      ## (i.e. the response was *not* `truncated:true, payload:@[]`).
    fetchHitsPeer*: uint64
      ## Client-side: `requestFetch` returned `some(payload)` from a
      ## sibling peer (LAN tier-1).
    fetchHitsTier2*: uint64
      ## Client-side: `requestFetch` resolved against a peer marked
      ## tier-2 (rack-local fat peer).
    fetchMissesTotal*: uint64
      ## Both sides: count of fetches that returned `truncated:true` or
      ## `requestFetch` returned `none`.
    advertisementsSentTotal*: uint64
      ## Outbound `mkAdvertise` / `mkAdvertiseV2` frames sent by the
      ## owning peer (server or client).
    advertisementsReceivedTotal*: uint64
      ## Inbound `mkAdvertise` / `mkAdvertiseV2` frames the receiver
      ## decoded and applied.
    signatureRejectionsTotal*: uint64
      ## Mirror of `server.signatureRejectedCount + client.signatureRejectedCount`
      ## updated by `sampleFromServer` / `sampleFromClient`. Exposed as
      ## a counter on the scrape endpoint so dashboards can alert on a
      ## sudden rise.
    swimPingsTotal*: uint64
      ## SWIM direct-probe sends. Bumped by the engine each protocol
      ## period.
    swimPingAcksTotal*: uint64
      ## SWIM ack receipts (direct + indirect).

    # ---- gauges ----
    activePeers*: int
      ## Snapshot of `registry.peerCount()` written by
      ## `sampleFromServer` / `sampleFromClient`.
    poolConnsActive*: int
      ## Peer-Cache-Scale M4: count of pooled connections currently
      ## checked out (`inUse == true`).
    poolConnsIdle*: int
      ## Peer-Cache-Scale M4: pooled connections currently sitting
      ## idle (open, `inUse == false`).

    # ---- histograms ----
    fetchLatencyBuckets*: array[8, uint64]
      ## Bucket counters for fetch latency (ms). Buckets are inclusive
      ## upper bounds defined by `FetchLatencyBucketsMs`; the last
      ## bucket is `+Inf`.
    fetchLatencyCount*: uint64
    fetchLatencySumMs*: uint64

    # ---- registry snapshot for /debug/peers ----
    lastRegistrySnapshot*: seq[PeerSummary]
      ## Most recent registry summary written by
      ## `refreshDebugRegistry`. Read by the JSON `/debug/peers`
      ## handler.

  PeerSummary* = object
    peerId*: string
    host*: string
    port*: uint16
    isTier2*: bool
    blobCount*: int

# ---------------------------------------------------------------------------
# Construction.
# ---------------------------------------------------------------------------

proc newPeerCacheMetrics*(): PeerCacheMetrics =
  PeerCacheMetrics(
    fetchRequestsTotal: 0,
    fetchHitsLocal: 0,
    fetchHitsPeer: 0,
    fetchHitsTier2: 0,
    fetchMissesTotal: 0,
    advertisementsSentTotal: 0,
    advertisementsReceivedTotal: 0,
    signatureRejectionsTotal: 0,
    swimPingsTotal: 0,
    swimPingAcksTotal: 0,
    activePeers: 0,
    poolConnsActive: 0,
    poolConnsIdle: 0,
    fetchLatencyBuckets: [0'u64, 0, 0, 0, 0, 0, 0, 0],
    fetchLatencyCount: 0,
    fetchLatencySumMs: 0,
    lastRegistrySnapshot: @[])

# ---------------------------------------------------------------------------
# Mutation helpers — used by `client.nim` / `server.nim` increment sites.
# ---------------------------------------------------------------------------

proc recordFetchLatency*(m: PeerCacheMetrics; ms: int) =
  ## Records one fetch latency observation. The first cap that the
  ## observation `<=` to wins; anything larger than the last finite cap
  ## lands in `+Inf` (bucket index 7).
  if m.isNil:
    return
  inc m.fetchLatencyCount
  m.fetchLatencySumMs += uint64(max(ms, 0))
  for i in 0 .. 6:
    if ms <= FetchLatencyBucketsMs[i]:
      inc m.fetchLatencyBuckets[i]
      return
  inc m.fetchLatencyBuckets[7]

proc setPoolGauges*(m: PeerCacheMetrics; active, idle: int) =
  ## Convenience helper called by the connection pool after every
  ## acquire/release/reap.
  if m.isNil:
    return
  m.poolConnsActive = active
  m.poolConnsIdle = idle

proc setActivePeers*(m: PeerCacheMetrics; n: int) =
  if m.isNil:
    return
  m.activePeers = n

proc refreshDebugRegistry*(m: PeerCacheMetrics; registry: PeerRegistry) =
  ## Recomputes the `/debug/peers` snapshot from the registry. The
  ## handler reads this rather than walking the live registry under the
  ## HTTP request to keep the response cheap and lock-free.
  if m.isNil or registry.isNil:
    return
  var summary: seq[PeerSummary] = @[]
  for peerId, entry in registry.entries.pairs:
    let bc =
      if entry.advertised.isNil: 0
      else: int(entry.advertised.count)
    summary.add(PeerSummary(
      peerId: $peerId,
      host: entry.endpoint.host,
      port: uint16(entry.endpoint.port),
      isTier2: entry.isTier2,
      blobCount: bc))
  m.lastRegistrySnapshot = summary

# ---------------------------------------------------------------------------
# Prometheus exposition format.
# ---------------------------------------------------------------------------

proc help(name, doc, kind: string): string =
  "# HELP " & name & " " & doc & "\n# TYPE " & name & " " & kind & "\n"

proc renderHistogram(m: PeerCacheMetrics): string =
  result = help("repro_peer_cache_fetch_latency_seconds",
                "Per-fetch wall-clock latency in seconds", "histogram")
  var cumulative: uint64 = 0
  for i in 0 .. 6:
    cumulative += m.fetchLatencyBuckets[i]
    let leSec = float(FetchLatencyBucketsMs[i]) / 1000.0
    result.add(&"repro_peer_cache_fetch_latency_seconds_bucket{{le=\"{leSec:0.3f}\"}} {cumulative}\n")
  cumulative += m.fetchLatencyBuckets[7]
  result.add("repro_peer_cache_fetch_latency_seconds_bucket{le=\"+Inf\"} " &
             $cumulative & "\n")
  result.add("repro_peer_cache_fetch_latency_seconds_count " &
             $m.fetchLatencyCount & "\n")
  let sumSec = float(m.fetchLatencySumMs) / 1000.0
  result.add(&"repro_peer_cache_fetch_latency_seconds_sum {sumSec:0.3f}\n")

proc renderPrometheus*(m: PeerCacheMetrics): string =
  ## Produces a Prometheus text-format exposition. The order matters
  ## for some scrapers (Prometheus tolerates any order; the
  ## `prometheus_client_python` parser requires `# HELP` / `# TYPE`
  ## immediately before the first sample). The output is ASCII-only.
  if m.isNil:
    return ""
  result = ""

  # Counters.
  result.add(help("repro_peer_cache_fetch_requests_total",
                  "Total mkFetchRequest frames answered", "counter"))
  result.add("repro_peer_cache_fetch_requests_total " &
             $m.fetchRequestsTotal & "\n")

  result.add(help("repro_peer_cache_fetch_hits_local_total",
                  "Fetch hits served from the local store", "counter"))
  result.add("repro_peer_cache_fetch_hits_local_total " &
             $m.fetchHitsLocal & "\n")

  result.add(help("repro_peer_cache_fetch_hits_peer_total",
                  "Fetch hits served from a sibling peer", "counter"))
  result.add("repro_peer_cache_fetch_hits_peer_total " &
             $m.fetchHitsPeer & "\n")

  result.add(help("repro_peer_cache_fetch_hits_tier2_total",
                  "Fetch hits served from a tier-2 peer", "counter"))
  result.add("repro_peer_cache_fetch_hits_tier2_total " &
             $m.fetchHitsTier2 & "\n")

  result.add(help("repro_peer_cache_fetch_misses_total",
                  "Fetch attempts that returned truncated or none",
                  "counter"))
  result.add("repro_peer_cache_fetch_misses_total " &
             $m.fetchMissesTotal & "\n")

  result.add(help("repro_peer_cache_advertisements_sent_total",
                  "Outbound advertise frames sent", "counter"))
  result.add("repro_peer_cache_advertisements_sent_total " &
             $m.advertisementsSentTotal & "\n")

  result.add(help("repro_peer_cache_advertisements_received_total",
                  "Inbound advertise frames applied", "counter"))
  result.add("repro_peer_cache_advertisements_received_total " &
             $m.advertisementsReceivedTotal & "\n")

  result.add(help("repro_peer_cache_signature_rejections_total",
                  "Tampered/unverifiable signed advertisements",
                  "counter"))
  result.add("repro_peer_cache_signature_rejections_total " &
             $m.signatureRejectionsTotal & "\n")

  result.add(help("repro_peer_cache_swim_pings_total",
                  "SWIM direct-probe sends", "counter"))
  result.add("repro_peer_cache_swim_pings_total " &
             $m.swimPingsTotal & "\n")

  result.add(help("repro_peer_cache_swim_ping_acks_total",
                  "SWIM probe acknowledgements received", "counter"))
  result.add("repro_peer_cache_swim_ping_acks_total " &
             $m.swimPingAcksTotal & "\n")

  # Gauges.
  result.add(help("repro_peer_cache_active_peers",
                  "Current peer registry size", "gauge"))
  result.add("repro_peer_cache_active_peers " & $m.activePeers & "\n")

  result.add(help("repro_peer_cache_pool_conns_active",
                  "Pooled connections currently checked out", "gauge"))
  result.add("repro_peer_cache_pool_conns_active " &
             $m.poolConnsActive & "\n")

  result.add(help("repro_peer_cache_pool_conns_idle",
                  "Pooled connections sitting idle", "gauge"))
  result.add("repro_peer_cache_pool_conns_idle " &
             $m.poolConnsIdle & "\n")

  result.add(renderHistogram(m))

# ---------------------------------------------------------------------------
# /debug/peers JSON renderer.
# ---------------------------------------------------------------------------

proc jsonEscape(s: string): string =
  result = ""
  for ch in s:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      if ch.uint8 < 0x20:
        result.add("\\u00")
        const Hex = "0123456789abcdef"
        result.add(Hex[(ch.uint8 shr 4) and 0xf])
        result.add(Hex[ch.uint8 and 0xf])
      else:
        result.add(ch)

proc renderPeersJson*(m: PeerCacheMetrics): string =
  ## Produces a JSON array suitable for the `/debug/peers` admin
  ## endpoint. Hand-rolled to keep the metrics module dependency-free.
  if m.isNil:
    return "[]"
  result = "["
  var first = true
  for p in m.lastRegistrySnapshot:
    if not first:
      result.add(",")
    first = false
    result.add("{\"peerId\":\"")
    result.add(jsonEscape(p.peerId))
    result.add("\",\"host\":\"")
    result.add(jsonEscape(p.host))
    result.add("\",\"port\":")
    result.add($p.port)
    result.add(",\"isTier2\":")
    result.add(if p.isTier2: "true" else: "false")
    result.add(",\"blobCount\":")
    result.add($p.blobCount)
    result.add("}")
  result.add("]")

# ---------------------------------------------------------------------------
# HTTP server.
# ---------------------------------------------------------------------------

proc parseListenAddr(spec: string): tuple[host: string, port: Port] =
  ## Parses `host:port`. Defaults to `0.0.0.0` when no host present.
  let colon = spec.rfind(':')
  if colon <= 0:
    raise newException(ValueError,
      "metrics listen addr must be host:port, got: " & spec)
  let host = spec[0 ..< colon]
  let portStr = spec[colon + 1 .. ^1]
  let port = Port(parseInt(portStr))
  (host: (if host.len == 0: "0.0.0.0" else: host), port: port)

proc handleHttpRequest*(m: PeerCacheMetrics;
                        req: Request): Future[void] {.async.} =
  ## Single-handler entrypoint shared by `startMetricsServer` and the
  ## test (which calls this directly rather than spawning a listener).
  let path = req.url.path
  if req.reqMethod != HttpGet:
    await req.respond(Http405, "method not allowed")
    return
  case path
  of "/metrics":
    let body = renderPrometheus(m)
    var headers = newHttpHeaders()
    headers["Content-Type"] = PrometheusContentType
    await req.respond(Http200, body, headers)
  of "/debug/peers":
    let body = renderPeersJson(m)
    var headers = newHttpHeaders()
    headers["Content-Type"] = JsonContentType
    await req.respond(Http200, body, headers)
  of "/healthz":
    await req.respond(Http200, "ok")
  else:
    await req.respond(Http404, "not found")

type
  MetricsServer* = ref object
    ## Lifecycle holder for the running HTTP server. Tests `close()`
    ## the underlying `AsyncHttpServer` so the dispatcher doesn't hang
    ## on shutdown.
    server*: AsyncHttpServer
    metrics*: PeerCacheMetrics
    listenHost*: string
    listenPort*: Port
    running*: bool

proc newMetricsServer*(m: PeerCacheMetrics): MetricsServer =
  MetricsServer(
    server: newAsyncHttpServer(),
    metrics: m,
    listenHost: "",
    listenPort: Port(0),
    running: false)

proc start*(s: MetricsServer; listenAddr: string) {.async.} =
  ## Binds the HTTP server on `listenAddr` and runs the accept loop
  ## until `close()` is called. The accept loop is driven by
  ## `asyncCheck` so the caller's `await` returns immediately after
  ## bind.
  let (host, port) = parseListenAddr(listenAddr)
  s.listenHost = host
  s.listenPort = port
  s.running = true
  let m = s.metrics
  proc cb(req: Request) {.async.} =
    if not s.running:
      return
    await handleHttpRequest(m, req)
  asyncCheck s.server.serve(port, cb, host)

proc startMetricsServer*(m: PeerCacheMetrics;
                         listenAddr: string): Future[MetricsServer]
                         {.async.} =
  ## Convenience helper used by daemons that want a one-call bind. The
  ## returned server is held by the caller for later `close()`.
  result = newMetricsServer(m)
  await result.start(listenAddr)

proc close*(s: MetricsServer) =
  if s.isNil or not s.running:
    return
  s.running = false
  try: s.server.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Structured JSON event stream — Peer-Cache-Scale M4.
# ---------------------------------------------------------------------------

type
  EventLog* = ref object
    ## Append-only JSONL writer used by the daemon when
    ## `--event-log=<path>` is configured. Each `emit` flushes one
    ## record so a tail -F can consume the stream live.
    path*: string
    file*: File
    isOpen*: bool

proc openEventLog*(path: string): EventLog =
  ## Opens the file in append-mode. Idempotent in the sense that
  ## multiple opens against the same path produce independent handles
  ## (the daemon usually keeps a single one).
  let f = open(path, fmAppend)
  EventLog(path: path, file: f, isOpen: true)

proc closeLog*(log: EventLog) =
  if log.isNil or not log.isOpen:
    return
  log.isOpen = false
  try: log.file.close() except CatchableError: discard

proc nowIsoUtc(): string =
  ## RFC-3339 UTC timestamp with millisecond precision. Hand-rolled to
  ## avoid pulling `times.format` into the metrics module.
  let t = epochTime()
  let whole = int64(t)
  let ms = int((t - float(whole)) * 1000.0)
  let tm = utc(fromUnix(whole))
  &"{tm.year:04}-{ord(tm.month):02}-{tm.monthday:02}T{tm.hour:02}:{tm.minute:02}:{tm.second:02}.{ms:03}Z"

proc emit*(log: EventLog; event: string;
           fields: openArray[(string, string)]) =
  ## Writes one JSON record per line. Field values are encoded
  ## verbatim — the caller is responsible for JSON-quoting strings
  ## (use `quoteString` below) and stringifying numbers.
  if log.isNil or not log.isOpen:
    return
  var line = "{\"ts\":\"" & nowIsoUtc() & "\",\"event\":\""
  line.add(jsonEscape(event))
  line.add("\"")
  for (k, v) in fields:
    line.add(",\"")
    line.add(jsonEscape(k))
    line.add("\":")
    line.add(v)
  line.add("}\n")
  try:
    log.file.write(line)
    log.file.flushFile()
  except CatchableError:
    discard

proc quoteString*(s: string): string =
  ## Wrap an arbitrary string in JSON quoting suitable for `emit`'s
  ## `fields` values.
  "\"" & jsonEscape(s) & "\""

# ---------------------------------------------------------------------------
# Wall-clock helper.
# ---------------------------------------------------------------------------

proc nowMs*(): int64 =
  ## Monotone-ish wall-clock used to measure fetch latencies. We use
  ## epoch milliseconds rather than `MonoTime` so the value is
  ## directly comparable across `requestFetch` boundaries that span
  ## an `await`.
  (epochTime() * 1000.0).int64
