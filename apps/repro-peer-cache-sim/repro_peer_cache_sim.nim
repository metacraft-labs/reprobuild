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
                            [--out=PATH]

Runs the Peer-Cache-Scale M5 simulation in this process and prints
(or writes) the demonstration report.
"""

type Options = object
  numPeers: int
  probeMs: int
  blobsPerPeer: int
  fetchesPerPeer: int
  outPath: string

proc parseArgs(): Options =
  result = Options(
    numPeers: 200,
    probeMs: 50,
    blobsPerPeer: 8,
    fetchesPerPeer: 10,
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

proc preamble(opts: Options; convergeMs: int): string =
  result = ""
  result.add("Generated: " & ($now())[0 .. 18] & "\n\n")
  let host = uname()
  if host.len > 0:
    result.add("Hardware: " & host & "\n\n")
  result.add(&"Fleet size: {opts.numPeers} peers\n\n")
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

  echo "Spawning ", opts.numPeers, "-peer simulation fleet..."
  let specs = defaultSimSpecs(opts.numPeers, racks = 5, tenants = 2)
  var fleet = await spawnSimFleet(specs, cfg, seedsPerPeer = 5)
  let startedAll = getMonoTime()
  try:
    startSwim(fleet)
    echo "Awaiting SWIM convergence..."
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
    var md = "# Peer-Cache-Scale M5 demonstration report\n\n"
    md.add(preamble(opts, convergeMs))
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
