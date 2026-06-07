## Peer-Cache-Scale M5 demonstration driver.
##
## Runs the 200-peer in-process simulation, collects the report, and
## either prints the rendered Markdown to stdout or writes it to the
## path supplied via `--out=<path>`. Used by the M5 demonstration
## report workflow to materialise
## `reprobuild-specs/Peer-Cache-Scale-M5-Demonstration.md`.

import std/[asyncdispatch, monotimes, os, osproc, parseopt, strutils,
            strformat, times]

import repro_peer_cache

const Usage = """
usage: repro-peer-cache-sim [--peers=N] [--probe=MS]
                            [--blobs=N] [--fetches=N]
                            [--trust-mode={tmCidr|tmTls}]
                            [--tls-enabled={true|false}]
                            [--tenants=N] [--racks=N]
                            [--out=PATH]

Runs the Peer-Cache-Scale M5 simulation in this process and prints
(or writes) the demonstration report.

`--trust-mode=tmCidr` (default) reproduces the Peer-Cache-Scale M5
baseline. `--trust-mode=tmTls` opts every peer into the BearSSL
ECDSA-P256 sign/verify path on the seeded AdvertiseV2 payload; the
in-process transport short-circuits the actual TLS wrap unless
`--tls-enabled=true` is also passed.
"""

type
  TrustModeOpt = enum
    tmoCidr, tmoTls

  Options = object
    numPeers: int
    probeMs: int
    blobsPerPeer: int
    fetchesPerPeer: int
    trustMode: TrustModeOpt
    tlsEnabled: bool
    tenants: int
    racks: int
    outPath: string

proc parseTrustMode(val: string): TrustModeOpt =
  let v = val.toLowerAscii()
  case v
  of "tmcidr", "cidr": tmoCidr
  of "tmtls", "tls": tmoTls
  else:
    echo "unknown --trust-mode value: ", val,
         " (expected tmCidr|tmTls)"
    quit(2)

proc parseBool(val: string): bool =
  case val.toLowerAscii()
  of "true", "1", "yes", "on": true
  of "false", "0", "no", "off": false
  else:
    echo "unknown bool value: ", val,
         " (expected true|false)"
    quit(2)

proc parseArgs(): Options =
  result = Options(
    numPeers: 200,
    probeMs: 50,
    blobsPerPeer: 8,
    fetchesPerPeer: 10,
    trustMode: tmoCidr,
    tlsEnabled: false,
    tenants: 2,
    racks: 5,
    outPath: "")
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption:
      case key.toLowerAscii()
      of "peers": result.numPeers = parseInt(val)
      of "probe": result.probeMs = parseInt(val)
      of "blobs": result.blobsPerPeer = parseInt(val)
      of "fetches": result.fetchesPerPeer = parseInt(val)
      of "trust-mode", "trustmode": result.trustMode = parseTrustMode(val)
      of "tls-enabled", "tlsenabled": result.tlsEnabled = parseBool(val)
      of "tenants": result.tenants = parseInt(val)
      of "racks": result.racks = parseInt(val)
      of "out": result.outPath = val
      of "help":
        echo Usage
        quit(0)
      else:
        echo "unknown option: --", key
        quit(2)
    of cmdShortOption:
      if key == "h":
        echo Usage
        quit(0)
    else: discard

proc uname(): string =
  try:
    let (output, code) = execCmdEx("uname -a")
    if code == 0:
      return output.strip()
  except CatchableError:
    discard
  ""

proc trustModeLabel(opts: Options): string =
  case opts.trustMode
  of tmoCidr: "tmCidr"
  of tmoTls: "tmTls"

proc preamble(opts: Options; convergeMs: int;
              signaturesVerified, signaturesRejected: uint64): string =
  result = ""
  result.add("Generated: " & ($now())[0 .. 18] & "\n\n")
  let host = uname()
  if host.len > 0:
    result.add("Hardware: " & host & "\n\n")
  result.add(&"Fleet size: {opts.numPeers} peers\n\n")
  result.add(&"Rack count: {opts.racks}\n\n")
  result.add(&"Tenant count: {opts.tenants}\n\n")
  result.add(&"Trust mode: {trustModeLabel(opts)}\n\n")
  if opts.trustMode == tmoTls:
    let tlsLabel =
      if opts.tlsEnabled:
        "real BearSSL TLS 1.2 wrap (opt-in)"
      else:
        "in-process short-circuit (default; the sim still runs real " &
          "ECDSA-P256 sign + verify on every dissemination round)"
    result.add(&"TLS in-process pass: {tlsLabel}\n\n")
    result.add(&"Real ECDSA-P256 verifies performed: {signaturesVerified}\n\n")
    result.add(&"Signature rejections (sim layer): {signaturesRejected}\n\n")
  result.add(&"Probe period: {opts.probeMs} ms\n\n")
  result.add(&"Seeded blobs per peer: {opts.blobsPerPeer}\n\n")
  result.add(&"Fetches per peer: {opts.fetchesPerPeer}\n\n")
  if convergeMs >= 0:
    result.add(&"SWIM convergence wall-clock: {convergeMs} ms\n\n")
  else:
    result.add("SWIM convergence: incomplete inside the budget\n\n")

proc main() {.async.} =
  let opts = parseArgs()
  var cfg = defaultSwimConfig()
  cfg.swimProbePeriodMs = opts.probeMs
  cfg.swimProbeTimeoutMs = 20
  cfg.swimGossipMessageCap = 32

  let tm =
    case opts.trustMode
    of tmoCidr: tmCidr
    of tmoTls: tmTls

  var tlsSmokeOk = false
  if opts.trustMode == tmoTls and opts.tlsEnabled:
    echo "Running real-TLS-in-process smoke pass (4 loopback peers)..."
    tlsSmokeOk = await runTlsHandshakeSmokePass(4)
    if tlsSmokeOk:
      echo "  TLS smoke pass: ok (4 peers settled via real BearSSL handshakes)"
    else:
      echo "  TLS smoke pass: FAILED (handshake-driven membership did not " &
           "settle within 8 s)"

  echo "Spawning ", opts.numPeers, "-peer simulation fleet ",
       "(trust=", trustModeLabel(opts),
       ", tlsEnabled=", opts.tlsEnabled, ")..."
  let specs = defaultSimSpecs(
    opts.numPeers, racks = opts.racks, tenants = opts.tenants,
    trustMode = tm)
  let fleetOptions = defaultSimFleetOptions(
    seedsPerPeer = 5, tlsEnabled = opts.tlsEnabled)
  var fleet = await spawnSimFleet(
    specs, cfg, seedsPerPeer = 5, options = fleetOptions)
  let startedAll = getMonoTime()
  try:
    startSwim(fleet)
    echo "Awaiting SWIM convergence..."
    # In tmTls mode the per-peer membership cap shrinks to the
    # tenant-local population. Use the wider numPeers - 1 target; the
    # `waitForConvergence` helper caps per-peer against the tenant
    # automatically.
    let convergeMs = await waitForConvergence(
      fleet, opts.numPeers - 1, 30_000)
    if convergeMs < 0:
      echo "  convergence: did not complete inside 30 s"
    else:
      echo "  convergence: ", convergeMs, " ms"
    echo "Seeding blobs..."
    await seedRandomBlobs(fleet, opts.blobsPerPeer, 32)
    echo "Running workload..."
    await runWorkload(fleet, opts.fetchesPerPeer)
    let durationMs = (getMonoTime() - startedAll).inMilliseconds.int
    let report = collectReport(
      fleet, durationMs, convergeMs, swimProbePeriodMs = opts.probeMs)
    let reportTitle =
      if opts.trustMode == tmoTls:
        "# Peer-Cache-BearSSL M5 demonstration report\n\n"
      else:
        "# Peer-Cache-Scale M5 demonstration report\n\n"
    var md = reportTitle
    md.add(preamble(opts, convergeMs,
                    fleet.signaturesVerified,
                    fleet.signaturesRejected))
    md.add(renderReportMarkdown(report))
    if opts.outPath.len > 0:
      writeFile(opts.outPath, md)
      echo "Wrote ", opts.outPath
    else:
      echo md
  finally:
    await shutdownFleet(fleet)
    for _ in 0 ..< 10:
      try: poll(0) except ValueError: discard

when isMainModule:
  waitFor main()
