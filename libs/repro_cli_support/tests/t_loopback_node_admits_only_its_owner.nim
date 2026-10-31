## Distributed-Execution M7, deviation D3 closed: a peer-cache node on
## loopback admits its OWNER and no other local user.
##
## Until D3 was closed, a node the CLI or the daemon started without `tls=1`
## ran in CIDR-only trust: a caller connecting from `127.0.0.1` was admitted
## to the content plane whoever it was — on a shared host (a CI machine with
## several tenants) that is every local user. CIDR-only trust is now removed
## from every shipped entry point (`parsePeerCache` refuses `tls=0`,
## `peer_cache_wiring.validateListenerPolicy` refuses a non-TLS node on any
## interface, the tier-2 daemon refuses to start without TLS); admission is
## the node's host CA, whose key `identity.loadOrCreateHostIdentity` writes
## readable by the owning user only.
##
## Node D is built exactly as the CLI and the daemon build one: the CLI's
## own parse of a spec that does NOT say `tls=1`, then `startPeerCacheHost`.
## A blob sits in D's CAS.
##
##   * CIDR trust is refused outright: `tls=0` does not parse, and a node
##     forced into CIDR trust does not start;
##   * the OWNER is admitted: a second node O of the same user, whose host CA
##     the owner pinned in D's anchor directory, fetches the blob over TLS
##     (the positive control — the refusals below are decisions, not a dead
##     listener);
##   * an address is not an identity: a plain-TCP caller on loopback (the
##     old CIDR-mode request) gets nothing, from any user;
##   * ANOTHER LOCAL UID (`nobody`, via `sudo -n -u nobody`) running
##     this same binary as a probe gets nothing four ways: it cannot read
##     D's host-CA key, cannot add its own CA to D's anchors, is refused at
##     the TLS handshake with a CA of its own, and gets no answer as a
##     plain-TCP caller. Runs on Linux and macOS alike; only a host where
##     no second uid can be had without a password declares
##     `[platform N/A]`.
##
## The reddening negative control (restoring CIDR-only trust for a loopback
## node: the plain-TCP request is then served, to `nobody` too) is a neuter
## experiment recorded in the milestone's Verification log.
##
## MOCK POLICY — none: real loopback sockets, real BearSSL, real
## certificates and file permissions, a real second OS user.

import std/[asyncdispatch, options, os, osproc, streams, strutils, times, unittest]

import repro_cas_store
import repro_cli_support
import repro_cli_support/peer_cache_wiring
import repro_peer_cache
import repro_test_support/reasoned_skip

const ProbeEnv = "REPRO_TEST_LOOPBACK_PROBE"

proc hexOf(bytes: openArray[byte]): string =
  for b in bytes: result.add(toHex(b, 2).toLowerAscii)

proc arrayOfHex(hex: string): array[32, byte] =
  let raw = fromHexLower(hex)
  doAssert raw.len == 32
  for i in 0 ..< 32: result[i] = raw[i]

proc pumpFor(ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    try: poll(20) except ValueError: sleep(20)

proc plainFetch(port: int; peer: PeerId; digest: BlobDigest): bool =
  ## The old CIDR-mode request: a client with no credential dials the node
  ## on loopback and asks for the blob. True when bytes come back.
  let me = peerIdFromBytes(arrayOfHex(repeat("ab", 32)))
  let c = newPeerCacheClient(me, 0'u16,
    newPeerRegistry(me, initEndpoint("127.0.0.1", Port(0))),
    @[initEndpoint("127.0.0.1", Port(port))], @[parseCidrV4("127.0.0.0/8")])
  try:
    waitFor c.start()
    pumpFor(300)
    result = (waitFor c.requestFetchFrom(peer, digest)).isSome
  except CatchableError:
    result = false
  finally:
    try: waitFor c.stop() except CatchableError: discard

proc strangerTlsFetch(port: int; peer: PeerId; digest: BlobDigest;
                      nodeCert, scratch: string): bool =
  ## A caller with a host CA of its OWN (trusting D, not trusted by D).
  createDir(scratch / "anchors")
  let me = loadOrCreateHostIdentity(scratch / "host-ca.crt",
    scratch / "host-ca.key")
  try: copyFile(nodeCert, scratch / "anchors" / "node.crt")
  except OSError: return false   # cannot even read D's certificate
  let leaf = mintLeaf(me, lrDaemon)
  let c = newPeerCacheClient(me.hostId, 0'u16,
    newPeerRegistry(me.hostId, initEndpoint("127.0.0.1", Port(0))),
    @[initEndpoint("127.0.0.1", Port(port))], @[parseCidrV4("127.0.0.0/8")],
    trustMode = tmTls, ourCert = leaf.cert,
    trustAnchorSet = loadTrustAnchorDir(scratch / "anchors"))
  c.leafProvider = proc(): LeafCredential {.gcsafe.} = leaf
  c.requireShortLivedLeaves = true
  try:
    waitFor c.start()
    pumpFor(300)
    if not c.isConnected(peer): return false
    result = (waitFor c.requestFetchFrom(peer, digest)).isSome
  except CatchableError:
    result = false
  finally:
    try: waitFor c.stop() except CatchableError: discard

proc runProbe(spec: string) =
  ## Probe mode: `port|peerHex|digestHex|tlsDir|scratch`, run as another
  ## user. Prints one `probe:` line per attempt and exits 0.
  let f = spec.split('|')
  let port = parseInt(f[0])
  let peer = peerIdFromBytes(arrayOfHex(f[1]))
  let digest = blobDigestFromBytes(arrayOfHex(f[2]))
  let tlsDir = f[3]
  let scratch = f[4]
  var key = "denied"
  try:
    discard readFile(tlsDir / "host-ca.key")
    key = "READ"
  except IOError, OSError:
    discard
  var anchors = "denied"
  try:
    writeFile(tlsDir / "anchors" / "intruder.crt", "x")
    anchors = "WRITTEN"
  except IOError, OSError:
    discard
  let plain = if plainFetch(port, peer, digest): "SERVED" else: "refused"
  let tls = if strangerTlsFetch(port, peer, digest, tlsDir / "host-ca.crt",
                                scratch): "SERVED" else: "refused"
  echo "probe:uid=", getEnv("USER"), " key=", key, " anchors=", anchors,
    " plain=", plain, " tls=", tls
  quit(0)

if getEnv(ProbeEnv).len > 0:
  runProbe(getEnv(ProbeEnv))

proc nodeConfig(stateHome: string; seeds = ""): PeerCacheConfig =
  ## The CLI's own parse of a spec WITHOUT `tls=1`.
  let previous = getEnv("XDG_STATE_HOME")
  putEnv("XDG_STATE_HOME", stateHome)
  defer:
    if previous.len > 0: putEnv("XDG_STATE_HOME", previous)
    else: delEnv("XDG_STATE_HOME")
  var spec = "lan://127.0.0.0/8?multicast=0"
  if seeds.len > 0: spec.add("&seeds=" & seeds)
  let parsed = parsePeerCache(spec)
  doAssert parsed.ok, spec
  parsed.config

proc newBase(): string =
  ## Directly under /tmp (on macOS its real path, /private/tmp) so another
  ## user can reach the probe binary; every directory on the way is
  ## searchable by others. The per-user `TMPDIR` is owner-only on both.
  when defined(posix):
    let tmp =
      if symlinkExists("/tmp"): expandSymlink("/tmp").absolutePath("/")
      else: "/tmp"
    result = tmp / ("repro-d3-" & $getCurrentProcessId())
  else:
    result = getTempDir() / ("repro-d3-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc secondUidAvailable(): bool =
  ## Any POSIX host (Linux, macOS) where `nobody` can be had without a
  ## password. Not a platform question: m3 (macOS) and arch (Linux) both
  ## provide it, so the case runs on both.
  when defined(posix):
    findExe("sudo").len > 0 and
      execCmdEx("sudo -n -u nobody true").exitCode == 0
  else:
    false

suite "Distributed-Execution M7: a loopback node admits only its owner (D3)":

  var base = ""
  var hostD, hostO: PeerCacheHost
  var digest: BlobDigest
  var cfgD: PeerCacheConfig

  setup:
    base = newBase()
    cfgD = nodeConfig(base / "d" / "xdg")
    let cfgO = nodeConfig(base / "o" / "xdg")
    for cfg in [cfgD, cfgO]:
      discard loadOrCreateHostIdentity(cfg.tlsCertPath, cfg.tlsKeyPath)
    # The owner pins its own second node in D, and D in it.
    createDir(cfgD.tlsTrustAnchorsPath)
    createDir(cfgO.tlsTrustAnchorsPath)
    copyFile(cfgO.tlsCertPath, cfgD.tlsTrustAnchorsPath / "o.crt")
    copyFile(cfgD.tlsCertPath, cfgO.tlsTrustAnchorsPath / "d.crt")
    let idD = peerIdFromBytes(arrayOfHex(repeat("d0", 32)))
    hostD = startPeerCacheHost(cfgD, idD, cacheRoot = base / "d-cache")
    var cas = openCasStore(base / "d-cache")
    digest = blobDigestFromBytes(bytes(cas.casPut(
      cast[seq[byte]]("only for my owner\n"))))
    cas.close()

  teardown:
    if not hostO.isNil: hostO.stop()
    if not hostD.isNil: hostD.stop()
    hostO = nil
    hostD = nil
    removeDir(base)

  test "CIDR trust is refused; the owner is admitted; an address is not an identity":
    # The node the default spec builds is a TLS node on loopback.
    check cfgD.trustMode == tmTls
    check hostD.server.trustMode == tmTls
    check hostD.server.listenAddr == "127.0.0.1"
    check not parsePeerCache("lan://127.0.0.0/8?tls=0").ok
    var forced = cfgD
    forced.trustMode = tmCidr
    expect ValueError:
      discard startPeerCacheHost(forced,
        peerIdFromBytes(arrayOfHex(repeat("c1", 32))),
        cacheRoot = base / "forced-cache")
    # The owner's second node fetches the blob over TLS.
    hostO = startPeerCacheHost(nodeConfig(base / "o" / "xdg",
      "127.0.0.1:" & $int(hostD.actualPort)),
      peerIdFromBytes(arrayOfHex(repeat("0e", 32))),
      cacheRoot = base / "o-cache")
    pumpFor(500)
    check hostO.client.isConnected(hostD.selfPeerId)
    let got = waitFor hostO.client.requestFetchFrom(hostD.selfPeerId, digest)
    check got.isSome
    if got.isSome:
      check cast[string](got.get()) == "only for my owner\n"
    # The owner itself can read the key (it IS this node's identity) ...
    check readFile(cfgD.tlsKeyPath).len > 0
    # ... but a plain-TCP caller on loopback is not admitted, from any user.
    check not plainFetch(int(hostD.actualPort), hostD.selfPeerId, digest)

  test "another local uid is refused four ways":
    if not secondUidAvailable():
      echo "[platform N/A] a second local uid needs passwordless " &
        "`sudo -n -u nobody`, which this host does not grant"
      skip("platform N/A: no second local uid without a password")
    else:
      let probe = base / "probe"
      copyFile(getAppFilename(), probe)
      setFilePermissions(probe, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
      let scratch = base / "nobody-scratch"
      createDir(scratch)
      setFilePermissions(scratch, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead, fpOthersWrite,
        fpOthersExec})
      let spec = $int(hostD.actualPort) & "|" &
        hexOf(array[32, byte](hostD.selfPeerId)) & "|" &
        hexOf(array[32, byte](digest)) & "|" &
        cfgD.tlsCertPath.parentDir & "|" & scratch / "id"
      # The node keeps serving while the probe runs in another process.
      let p = startProcess("sudo", workingDir = base,
        args = ["-n", "-u", "nobody", "env", "USER=nobody",
                ProbeEnv & "=" & spec, probe],
        options = {poUsePath, poStdErrToStdOut})
      var output = ""
      let deadline = epochTime() + 60.0
      while p.running and epochTime() < deadline:
        pumpFor(100)
      output = p.outputStream.readAll()
      let code = p.waitForExit()
      p.close()
      # The probe's own files belong to `nobody`; it removes them itself.
      discard execCmdEx(quoteShellCommand(["sudo", "-n", "-u", "nobody",
        "rm", "-rf", scratch / "id"]))
      checkpoint("probe (exit " & $code & "): " & output)
      check code == 0
      check "probe:uid=nobody" in output
      check "key=denied" in output
      check "anchors=denied" in output
      check "plain=refused" in output
      check "tls=refused" in output
      check not fileExists(cfgD.tlsTrustAnchorsPath / "intruder.crt")
      # The stranger's handshake reached a DECISION at D.
      check hostD.server.tlsHandshakeRejectedCount >= 1
