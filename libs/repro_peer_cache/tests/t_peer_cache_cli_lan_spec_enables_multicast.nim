## Peer-Cache M2 verification test: the CLI parser
## ``parsePeerCache("lan://127.0.0.0/8:17654")`` returns a
## `PeerCacheConfig` with `discoveryMode = pdmMulticast`,
## `cidrAllowlistRaw` containing `127.0.0.0/8`, and
## `multicastGroup.port = Port(17654)`. Then
## `runReproTestCommand` invoked with ``--peer-cache=lan://...``
## against a fixture is expected to start the peer-cache services;
## we assert ``lastStartedPeerCacheRuntime.server.started == true``.
##
## The CLI surface and the ``lan://`` form are reserved by
## ``CI-Sharding.md`` §"CLI Surface"; Peer-Cache M2 wires the flag
## through to the multicast discovery plane in
## ``repro_peer_cache``.

import std/[asyncdispatch, json, nativesockets, os, tempfiles, unittest]

import repro_cli_support
import repro_peer_cache

suite "peer-cache CLI lan:// spec enables multicast":
  test "parsePeerCache lan://CIDR:port returns multicast config":
    let r = parsePeerCache("lan://127.0.0.0/8:17654")
    check r.ok
    check r.kind == pcsLan
    check r.config.discoveryMode == pdmMulticast
    check r.config.cidrAllowlistRaw.len == 1
    check r.config.cidrAllowlistRaw[0] == "127.0.0.0/8"
    check r.config.multicastGroup.port == Port(17654)
    # Defaults from the spec.
    check r.config.advertiseIntervalMs == DefaultAdvertiseIntervalMs
    check r.config.maxBlobBytes == DefaultMaxBlobBytes

  test "parsePeerCache lan://CIDR (no port) uses spec default":
    let r = parsePeerCache("lan://10.0.0.0/24")
    check r.ok
    check r.kind == pcsLan
    check r.config.multicastGroup.port == Port(DefaultMulticastPort)
    check r.config.cidrAllowlistRaw[0] == "10.0.0.0/24"

  test "parsePeerCache rejects malformed CIDR":
    let r = parsePeerCache("lan://not-a-cidr:17654")
    check not r.ok

  test "runReproTestCommand --peer-cache=lan starts the services":
    # Build a minimal fixture so `runReproTestCommand` has something
    # to plan. A single test edge + a single build action keeps the
    # runner fast.
    let tmpDir = createTempDir("peer_cache_cli_m2_", "")
    defer: removeDir(tmpDir)
    let fixturePath = tmpDir / "fixture.json"
    let logsDir = tmpDir / "test-logs"
    let reportPath = logsDir / "shard-report.json"
    createDir(logsDir)
    let fixture = %*{
      "buildActions": [
        {
          "id": 1, "commandStatsId": "bcache-test-build",
          "deps": [],
          "buildCmd": ["/bin/true"]
        }
      ],
      "testEdges": [
        {
          "id": 100, "selector": "test::dummy",
          "historyKey": "dummy",
          "buildDeps": [1],
          "runCmd": ["/bin/true"],
          "testName": "dummy"
        }
      ],
      "fallbackBuildCostNs": 1_000_000,
      "fallbackTestCostNs": 1_000_000,
      "policy": "independent"
    }
    writeFile(fixturePath, $fixture)

    # Pick a high port distinct from the discovery test groups so
    # parallel test runs don't conflict.
    let prevCwd = getCurrentDir()
    setCurrentDir(tmpDir)
    try:
      let exitCode = runReproTestCommand(
        @[
          "--shard", "1/1",
          "--fixture-from=" & fixturePath,
          "--report=" & reportPath,
          "--peer-cache=lan://127.0.0.0/8:17656"
        ],
        "")
      # The fixture build/run uses `/bin/true` so the runner returns
      # 0 — but if some environmental quirk surfaces a non-zero
      # code, we still want the peer-cache services to have
      # started, so check the runtime regardless of `exitCode`.
      discard exitCode
      let runtime = lastStartedPeerCacheRuntime
      check not runtime.server.isNil
      check runtime.server.started
    finally:
      setCurrentDir(prevCwd)
      let runtime = lastStartedPeerCacheRuntime
      if not runtime.client.isNil:
        try: waitFor runtime.client.stop() except CatchableError: discard
      if not runtime.server.isNil:
        runtime.server.stop()
