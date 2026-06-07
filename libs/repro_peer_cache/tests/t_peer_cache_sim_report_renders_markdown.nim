## Peer-Cache-Scale M5 verification: `renderReportMarkdown` produces
## the expected demonstration-report sections.

import std/[asyncdispatch, strutils, unittest]

import repro_peer_cache

suite "peer-cache simulation report":
  test "Markdown render contains every required section":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = 100
    let specs = defaultSimSpecs(10, racks = 2, tenants = 1)
    var fleet = waitFor spawnSimFleet(specs, cfg, seedsPerPeer = 3)
    try:
      startSwim(fleet)
      let convergeMs = waitFor waitForConvergence(fleet, 9, 5_000)
      check convergeMs >= 0
      waitFor seedRandomBlobs(fleet, 4, 16)
      waitFor runWorkload(fleet, 5)
      let report = collectReport(fleet, 0, convergeMs, swimProbePeriodMs = 100)
      let md = renderReportMarkdown(report)
      check "## Convergence" in md
      check "## Workload" in md
      check "## Latency" in md
      check "## Observability" in md
      check "Pool reuse ratio" in md
      check "Hit ratio" in md
      # JSON round-trip also smoke-tested.
      let js = renderReportJson(report)
      check js.startsWith("{") and js.endsWith("}")
      check "peerCount" in js
    finally:
      waitFor shutdownFleet(fleet)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
