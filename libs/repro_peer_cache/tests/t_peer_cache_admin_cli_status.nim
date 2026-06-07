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

proc repoRoot(): string =
  ## Walks up from the test binary's directory until we find an
  ## `apps/repro-peer-cache-admin` neighbour. The tests run from
  ## `libs/repro_peer_cache/tests/` so the walk is short.
  var dir = getCurrentDir()
  # Resolve based on the source file location instead; this is more
  # reliable when CI invokes the binary from a non-standard cwd.
  let here = currentSourcePath().parentDir()
  var d = here
  for _ in 0 ..< 6:
    if dirExists(d / "apps" / "repro-peer-cache-admin"):
      return d
    d = d.parentDir()
    if d.len == 0: break
  raise newException(OSError,
    "could not locate repo root from " & here)

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

    # 3. Locate + build the admin CLI binary.
    let root = repoRoot()
    let src = root / "apps" / "repro-peer-cache-admin" /
              "repro_peer_cache_admin.nim"
    let binDir = getTempDir() / "t_peer_cache_admin_cli"
    createDir(binDir)
    let binPath = binDir / "repro_peer_cache_admin_under_test"
    let libPath = root / "libs" / "repro_peer_cache" / "src"
    let compileCmd = "nim c --hints:off --path:" & libPath &
                     " -o:" & binPath & " " & src
    let compileResult = execCmdEx(compileCmd)
    check compileResult.exitCode == 0
    check fileExists(binPath)

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
