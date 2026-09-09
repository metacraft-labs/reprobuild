## Peer-Cache-Scale M4 verification: admin CLI `status` view renders
## the active-peer count + pool stats from a live metrics endpoint.
##
## Spawns a `PeerCacheMetrics` shell with non-zero counters, starts the
## metrics HTTP server, runs the admin CLI binary via `execProcess`
## against it, and asserts the rendered text contains the expected
## summary fields. Also covers the `peers` sub-command via the
## `/debug/peers` JSON path so the JSON renderer is exercised.
##
## See `Peer-Cache-Scale.milestones.org` §M4 verification list.

import std/[asyncdispatch, nativesockets, net, options, os, osproc,
            strutils, unittest]

import repro_peer_cache
from repro_test_support import graphArtifactPath, requireBinary

const
  PollIntervalMs = 25
  MaxBuildSeconds = 60

proc pumpDispatcher(ms: int) =
  var waited = 0
  while waited < ms:
    try: poll(0) except ValueError: discard
    sleep(PollIntervalMs)
    waited += PollIntervalMs

proc pickEphemeralPort(): int =
  var s = newSocket()
  defer:
    try: s.close() except CatchableError: discard
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(getLocalAddr(s.getFd(), Domain.AF_INET)[1])

# ``repoRoot()`` used to live here: a six-level walk upwards looking for an
# ``apps/repro-peer-cache-admin`` neighbour, whose only purpose was to feed the
# ad-hoc ``nim c`` this file no longer runs. ``graphArtifactPath`` resolves the
# graph-built binary against ``ReprobuildRepoRoot`` instead, which is derived
# once, in one place, from the checkout that contains the test-support source.

suite "peer-cache M4 admin CLI status":
  test "status sub-command prints active-peer count and pool stats":
    # 1. Build a metrics shell with realistic numbers.
    let m = newPeerCacheMetrics()
    setActivePeers(m, 5)
    setPoolGauges(m, 3, 2)
    inc m.fetchRequestsTotal
    inc m.fetchRequestsTotal
    inc m.fetchRequestsTotal
    inc m.fetchHitsLocal
    inc m.fetchHitsPeer
    inc m.fetchMissesTotal
    # Seed `/debug/peers` with two synthetic peers so the `peers`
    # sub-command has something to dump. We use a real registry to keep
    # the dependency tree honest.
    let selfId = peerIdFromBytes([byte 0x00, 0x01, 0x02, 0x03, 0x04,
                                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                  0, 0, 0, 0, 0])
    let registry = newPeerRegistry(selfId,
                                   initEndpoint("127.0.0.1", Port(0)))
    let p1Id = peerIdFromBytes([byte 'A', 1, 0, 0, 0, 0, 0, 0, 0, 0,
                                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    registry.addPeer(p1Id, initEndpoint("127.0.0.1", Port(31001)))
    refreshDebugRegistry(m, registry)

    # 2. Start metrics server on an ephemeral port.
    let port = pickEphemeralPort()
    let server = waitFor startMetricsServer(m, "127.0.0.1:" & $port)
    defer: server.close()
    pumpDispatcher(200)

    # 3. Resolve the graph-built admin CLI binary.
    #
    # Graph-Owned-Test-Artifacts M3: this block used to run ``nim c`` on
    # ``apps/repro-peer-cache-admin/repro_peer_cache_admin.nim`` into a temp
    # directory, on every run of every case. It is now resolved from the
    # SHIPPING app binary — the source is an entrypoint in
    # ``apps/entrypoints.txt`` and edge ``reprobuild.apps.repro-peer-cache-admin``
    # already builds it as ``build/bin/repro-peer-cache-admin`` — declared as a
    # typed input on this test's execute edge (``testFixtureArtifacts`` in
    # ``repro.nim``), so a change to the admin CLI re-runs this test rather
    # than being recompiled underneath it.
    #
    # Deliberately the app edge and not a test-only copy: a second edge over
    # the same source would build it twice, which is the property M3 exists to
    # remove. The binary a user ships is the binary this test exercises.
    #
    # The subject was never the compile: it is the text the admin CLI renders
    # from a live metrics endpoint.
    let binPath = requireBinary(
      graphArtifactPath("build/bin/repro-peer-cache-admin".addFileExt(
        ExeExt)),
      "reprobuild.apps.repro-peer-cache-admin")
    let binDir = getTempDir() / "t_peer_cache_admin_cli"
    createDir(binDir)

    # 4. Run admin subcommands. The server lives on the test's
    # dispatcher; we run the child with stdout/stderr redirected to a
    # temp file and pump `poll(0)` while the child runs so the
    # in-process metrics server can answer.
    proc runSubcmd(args: openArray[string]): tuple[exit: int, out0: string] =
      let outPath = binDir / ("out_" & args[0] & ".log")
      let shellArgs = binPath & " " & args.join(" ") & " >" & outPath &
                      " 2>&1"
      let pr = startProcess("/bin/sh", args = ["-c", shellArgs],
                            options = {poUsePath})
      var waited = 0
      while waited < 8_000:
        try: poll(0) except ValueError: discard
        let rc = pr.peekExitCode()
        if rc != -1:
          pr.close()
          var collected = ""
          if fileExists(outPath):
            collected = readFile(outPath)
          return (rc, collected)
        sleep(PollIntervalMs)
        waited += PollIntervalMs
      pr.kill()
      pr.close()
      var collected = ""
      if fileExists(outPath):
        collected = readFile(outPath)
      return (-1, collected)

    let url = "--metrics=http://127.0.0.1:" & $port
    let statusRes = runSubcmd(["status", url])
    check statusRes.exit == 0
    check "active_peers:" in statusRes.out0
    check "5" in statusRes.out0  # the active peer count
    check "pool_conns_active:" in statusRes.out0
    check "pool_conns_idle:" in statusRes.out0
    check "fetch_requests:" in statusRes.out0
    check "fetch_hit_rate:" in statusRes.out0

    let peersRes = runSubcmd(["peers", url])
    check peersRes.exit == 0
    check "peers (1)" in peersRes.out0

    let metricsRes = runSubcmd(["metrics", url])
    check metricsRes.exit == 0
    check "repro_peer_cache_fetch_requests_total" in metricsRes.out0
    check "# TYPE repro_peer_cache_active_peers gauge" in metricsRes.out0
