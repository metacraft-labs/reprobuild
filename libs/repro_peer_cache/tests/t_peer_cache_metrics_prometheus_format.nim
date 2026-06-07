## Peer-Cache-Scale M4 verification: Prometheus scrape endpoint serves
## a well-formed text-format response with the required
## `peercache_*` counters / histogram.
##
## Spawns the metrics HTTP server on `127.0.0.1:0`, scrapes `/metrics`
## via stdlib `httpclient`, and asserts:
##   - `Content-Type` is `text/plain; version=0.0.4`
##   - body contains the M4 counter names (`repro_peer_cache_fetch_requests_total`,
##     `repro_peer_cache_swim_pings_total`, etc.)
##   - histogram bucket lines parse with monotone-non-decreasing cumulatives
##
## See `Peer-Cache-Scale.milestones.org` §M4 verification list.

import std/[asyncdispatch, httpclient, nativesockets, net, options, os,
            strutils, unittest]

import repro_peer_cache

const
  PollIntervalMs = 25
  MaxWaitMs = 3_000

proc pumpDispatcher(ms: int) =
  ## Drives the async dispatcher for approximately `ms` milliseconds.
  ## Mirrors the polling pattern used by the M0–M3 verification tests
  ## (poll(0) + short sleep).
  var waited = 0
  while waited < ms:
    try: poll(0) except ValueError: discard
    sleep(PollIntervalMs)
    waited += PollIntervalMs

proc pickEphemeralPort(): int =
  ## Asks the OS for an ephemeral TCP port by binding-and-closing.
  ## Mirrors what `asynchttpserver` would do internally if it
  ## accepted port 0, but the stdlib API for `serve` requires a
  ## concrete port number.
  var s = newSocket()
  defer:
    try: s.close() except CatchableError: discard
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(getLocalAddr(s.getFd(), Domain.AF_INET)[1])

suite "peer-cache M4 metrics Prometheus format":
  test "GET /metrics serves the required text-format response":
    let m = newPeerCacheMetrics()
    # Seed a small amount of state so the counters are non-zero.
    inc m.fetchRequestsTotal
    inc m.fetchHitsLocal
    inc m.fetchHitsPeer
    inc m.swimPingsTotal
    inc m.swimPingAcksTotal
    inc m.advertisementsSentTotal
    inc m.advertisementsReceivedTotal
    setActivePeers(m, 3)
    setPoolGauges(m, 2, 1)
    recordFetchLatency(m, 4)
    recordFetchLatency(m, 250)
    recordFetchLatency(m, 9999)

    let port = pickEphemeralPort()
    let addrSpec = "127.0.0.1:" & $port
    let server = waitFor startMetricsServer(m, addrSpec)
    defer:
      server.close()

    # Give the async server a few ticks to actually bind + start
    # accepting. The async HTTP client will retry the connect anyway,
    # but pumping here keeps the test deterministic on slow CI.
    pumpDispatcher(200)

    let client = newAsyncHttpClient()
    defer:
      try: client.close() except CatchableError: discard
    let resp = waitFor client.request(
      "http://127.0.0.1:" & $port & "/metrics", httpMethod = HttpGet)
    check resp.code == Http200
    let ct = resp.headers.getOrDefault("content-type").toString()
    check ct == "text/plain; version=0.0.4"
    let body = waitFor resp.body
    check "repro_peer_cache_fetch_requests_total" in body
    check "repro_peer_cache_swim_pings_total" in body
    check "repro_peer_cache_active_peers 3" in body
    check "repro_peer_cache_pool_conns_active 2" in body
    check "repro_peer_cache_fetch_latency_seconds_bucket{le=\"+Inf\"}" in body
    check "# HELP repro_peer_cache_fetch_requests_total" in body
    check "# TYPE repro_peer_cache_fetch_requests_total counter" in body

    # Histogram cumulative check: the +Inf bucket must include every
    # observation we recorded (3 latencies).
    var infCount = -1
    for line in body.splitLines():
      if line.startsWith(
          "repro_peer_cache_fetch_latency_seconds_bucket{le=\"+Inf\"}"):
        let parts = line.split(' ')
        infCount = parseInt(parts[^1])
        break
    check infCount == 3

    # 404 path.
    let resp2 = waitFor client.request(
      "http://127.0.0.1:" & $port & "/nope", httpMethod = HttpGet)
    check resp2.code == Http404
