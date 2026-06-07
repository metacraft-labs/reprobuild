## Peer-Cache-Scale M4 admin CLI.
##
## Talks to a running `repro-peer-cache-tier2` daemon's metrics
## endpoint and renders one of three views:
##
##   repro-peer-cache-admin status  --metrics=http://host:port
##   repro-peer-cache-admin peers   --metrics=http://host:port
##   repro-peer-cache-admin metrics --metrics=http://host:port
##
## `status` parses the Prometheus text format and prints a one-shot
## human-readable summary (active peers, pool gauges, fetch hit rate,
## signature rejections).
##
## `peers` hits `GET /debug/peers` (JSON) on the same daemon and
## prints a one-line-per-peer summary.
##
## `metrics` is the raw `/metrics` dump.
##
## See `Peer-Cache-Scale.md` §"Admin CLI" and §"Connection lifecycle +
## observability".

import std/[httpclient, json, os, parseopt, strutils, tables]

const
  DefaultMetricsUrl = "http://127.0.0.1:9456"
  Usage = """
usage: repro-peer-cache-admin <command> [--metrics=URL]

commands:
  status   one-shot human-readable summary (peers, pool, fetch rate,
           signature rejection count)
  peers    JSON dump of the registry from GET /debug/peers
  metrics  raw Prometheus text from GET /metrics

flags:
  --metrics=URL      base URL of the running daemon's metrics
                     endpoint (default: http://127.0.0.1:9456)
  --timeout=MS       per-request timeout in milliseconds
                     (default: 5000)
  -h, --help         this message
"""

type
  AdminCmd* = enum
    acStatus, acPeers, acMetrics, acHelp

  AdminOpts* = object
    cmd*: AdminCmd
    metricsUrl*: string
    timeoutMs*: int

  AdminError* = object of CatchableError

proc parseCli*(argv: openArray[string]): AdminOpts =
  result = AdminOpts(
    cmd: acHelp,
    metricsUrl: DefaultMetricsUrl,
    timeoutMs: 5_000)
  if argv.len == 0:
    return
  var parser = initOptParser(@argv)
  var sawCmd = false
  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument:
      if not sawCmd:
        sawCmd = true
        case key
        of "status": result.cmd = acStatus
        of "peers": result.cmd = acPeers
        of "metrics": result.cmd = acMetrics
        of "help": result.cmd = acHelp
        else:
          raise newException(AdminError,
            "unknown subcommand: " & key)
    of cmdLongOption, cmdShortOption:
      case key
      of "metrics", "metrics-url":
        result.metricsUrl = val
      of "timeout", "timeout-ms":
        result.timeoutMs = parseInt(val)
      of "h", "help":
        result.cmd = acHelp
      else:
        raise newException(AdminError, "unknown flag: --" & key)
    of cmdEnd:
      break

# ---------------------------------------------------------------------------
# Prometheus text-format parser (single-value samples only).
# ---------------------------------------------------------------------------

proc parsePromCounters*(body: string): Table[string, float] =
  ## Parses every `metric_name SAMPLE` line into a table. Ignores
  ## `# HELP` / `# TYPE` lines and metrics with labels (the M4 surface
  ## only emits labelled lines for histograms; the admin CLI's status
  ## view doesn't need histogram bucket detail).
  result = initTable[string, float]()
  for line in body.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    # Skip labelled samples (they contain '{')
    if '{' in trimmed:
      continue
    let parts = trimmed.split(' ')
    if parts.len < 2:
      continue
    try:
      result[parts[0]] = parseFloat(parts[^1])
    except ValueError:
      discard

# ---------------------------------------------------------------------------
# HTTP helpers.
# ---------------------------------------------------------------------------

proc fetchUrl*(url: string; timeoutMs: int): string =
  ## Synchronous GET. We use the sync client because the admin CLI is
  ## one-shot and the metrics server is on a separate process.
  var client: HttpClient
  try:
    client = newHttpClient(timeout = timeoutMs)
    let resp = client.request(url, httpMethod = HttpGet)
    if resp.code != Http200:
      raise newException(AdminError,
        "GET " & url & " returned HTTP " & $resp.code)
    return resp.body
  finally:
    if not client.isNil:
      try: client.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Renderers.
# ---------------------------------------------------------------------------

proc renderStatus*(metricsBody: string): string =
  ## Builds the human-readable status summary. Exposed (not just used
  ## by `main`) so the verification test can call it without spinning
  ## up a real daemon — the test renders against synthetic body bytes.
  let counters = parsePromCounters(metricsBody)
  proc g(name: string): float =
    counters.getOrDefault(name, 0.0)
  let req = g("repro_peer_cache_fetch_requests_total")
  let hitsLocal = g("repro_peer_cache_fetch_hits_local_total")
  let hitsPeer = g("repro_peer_cache_fetch_hits_peer_total")
  let hitsTier2 = g("repro_peer_cache_fetch_hits_tier2_total")
  let misses = g("repro_peer_cache_fetch_misses_total")
  let hits = hitsLocal + hitsPeer + hitsTier2
  let total = hits + misses
  let hitRate =
    if total > 0.0: (hits / total) * 100.0 else: 0.0
  let active = g("repro_peer_cache_active_peers").int
  let poolActive = g("repro_peer_cache_pool_conns_active").int
  let poolIdle = g("repro_peer_cache_pool_conns_idle").int
  let sigRej = g("repro_peer_cache_signature_rejections_total").int

  result = ""
  result.add("peer-cache status:\n")
  result.add("  active_peers:        " & $active & "\n")
  result.add("  pool_conns_active:   " & $poolActive & "\n")
  result.add("  pool_conns_idle:     " & $poolIdle & "\n")
  result.add("  fetch_requests:      " & $int(req) & "\n")
  result.add("  fetch_hits_local:    " & $int(hitsLocal) & "\n")
  result.add("  fetch_hits_peer:     " & $int(hitsPeer) & "\n")
  result.add("  fetch_hits_tier2:    " & $int(hitsTier2) & "\n")
  result.add("  fetch_misses:        " & $int(misses) & "\n")
  result.add("  fetch_hit_rate:      " & formatFloat(hitRate, ffDecimal, 1) &
             "%\n")
  result.add("  signature_rejections: " & $sigRej & "\n")

proc renderPeers*(jsonBody: string): string =
  ## One-line-per-peer dump from the `/debug/peers` JSON array.
  let parsed = parseJson(jsonBody)
  if parsed.kind != JArray:
    raise newException(AdminError,
      "/debug/peers must return a JSON array, got " & $parsed.kind)
  result = ""
  result.add("peers (" & $parsed.len & "):\n")
  for entry in parsed:
    let pid = entry["peerId"].getStr()
    let host = entry["host"].getStr()
    let port = entry["port"].getInt()
    let tier2 = entry["isTier2"].getBool()
    let blobs = entry["blobCount"].getInt()
    let tag = if tier2: "tier2" else: "peer "
    result.add("  " & tag & " " & pid & "  " & host & ":" & $port &
               "  blobs=" & $blobs & "\n")

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------

proc runMain*(opts: AdminOpts): int =
  ## Returns the process exit code. Exposed for the verification test
  ## which calls `runMain` in-process rather than `execProcess`.
  case opts.cmd
  of acHelp:
    stdout.write(Usage)
    return 0
  of acStatus:
    try:
      let body = fetchUrl(opts.metricsUrl & "/metrics", opts.timeoutMs)
      stdout.write(renderStatus(body))
      return 0
    except CatchableError as err:
      stderr.writeLine("repro-peer-cache-admin: " & err.msg)
      return 1
  of acPeers:
    try:
      let body = fetchUrl(opts.metricsUrl & "/debug/peers", opts.timeoutMs)
      stdout.write(renderPeers(body))
      return 0
    except CatchableError as err:
      stderr.writeLine("repro-peer-cache-admin: " & err.msg)
      return 1
  of acMetrics:
    try:
      let body = fetchUrl(opts.metricsUrl & "/metrics", opts.timeoutMs)
      stdout.write(body)
      return 0
    except CatchableError as err:
      stderr.writeLine("repro-peer-cache-admin: " & err.msg)
      return 1

when isMainModule:
  var args: seq[string] = @[]
  for i in 1 .. paramCount():
    args.add(paramStr(i))
  try:
    let opts = parseCli(args)
    quit(runMain(opts))
  except AdminError as err:
    stderr.writeLine("repro-peer-cache-admin: " & err.msg)
    stderr.write(Usage)
    quit(2)
