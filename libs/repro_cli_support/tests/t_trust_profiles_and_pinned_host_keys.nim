## Distributed-Execution M7, TRUST PROFILES (operator decision 2026-10-20;
## `spec/Distributed-Execution-Threat-Model.md` §3a).
##
## 1. The default profile is `trusted`: a `lan://` spec without `profile=`
##    is trusted, `profile=hardened` selects hardened, anything else is a
##    parse error, a spec with two `profile=` keys is refused, and
##    `--trust-profile=` applies a profile to a spec — and refuses one that
##    contradicts the spec's own `profile=` or names it twice; the flag
##    itself given twice on the command line is refused
##    (`acceptTrustProfileFlag`).
## 2. `hardened` turns the hardened controls on, and `trusted` does not:
##    one-hour host-CA leaves vs the pinned long-lived host key; an off-host
##    evidence sink REQUIRED for a non-loopback listener vs not required;
##    `evidence=`/`signer=` refused on a trusted node (they are hardened
##    controls, never silently ignored); macOS and Windows lease confinement
##    refused in the hardened profile; on Linux a host without Landlock or a
##    subordinate uid range still runs a TRUSTED worker while the HARDENED
##    one is refused with the missing layer named — every combination
##    driven through `decideLinuxLeaseLayers`, and this host's own answer
##    checked to agree (hardened ok implies trusted ok).
## 3. Long-lived keys (trusted): mutual TLS verified in BOTH directions
##    against pinned host keys. A host whose key is NOT pinned is refused
##    when it dials (server side) and when it is dialled (client side); a
##    certificate merely SIGNED by a pinned key — a hardened-shape leaf with
##    a fresh key — is not a pinned key and is refused; removing the pin
##    revokes on the next frame and refuses the next handshake.
##
## MOCK POLICY — none: production hosts over real TLS, real host keys.

import std/[asyncdispatch, options, os, strutils, tables, tempfiles, times,
            unittest]

import repro_cas_store
import repro_peer_cache
import repro_cli_support
import repro_cli_support/peer_cache_wiring
import repro_distributed_worker

import ../../repro_peer_cache/tests/m7_test_pki

proc tickFor(hosts: openArray[PeerCacheHost]; ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    for h in hosts: h.tick(10)

proc blob(host: PeerCacheHost; text: string): BlobDigest =
  var bytes = newSeq[byte](text.len)
  for i, ch in text: bytes[i] = byte(ord(ch))
  var cas = openCasStore(host.storages[0].root)
  defer: cas.close()
  blobDigestFromBytes(bytes(cas.casPut(bytes)))

proc fetchOk(client: PeerCacheClient; peer: PeerId; d: BlobDigest): bool =
  client.fetchTimeoutMs = 1_500
  (waitFor client.requestFetchFrom(peer, d)).isSome

suite "Distributed-Execution M7: trust profiles":

  test "the default profile is trusted; hardened is opt-in":
    let plain = parsePeerCache("lan://127.0.0.0/8?tls=1")
    check plain.ok
    check plain.config.trustProfile == tpTrusted
    check default(PeerCacheConfig).trustProfile == tpTrusted
    let hard = parsePeerCache("lan://127.0.0.0/8?tls=1&profile=hardened")
    check hard.ok
    check hard.config.trustProfile == tpHardened
    check parsePeerCache("lan://127.0.0.0/8?profile=trusted").config.trustProfile ==
      tpTrusted
    check not parsePeerCache("lan://127.0.0.0/8?profile=paranoid").ok
    # --trust-profile= applies to the spec, and never contradicts it.
    check withTrustProfile("lan://127.0.0.0/8", "hardened") ==
      "lan://127.0.0.0/8?profile=hardened"
    check withTrustProfile("lan://127.0.0.0/8?tls=1", "hardened") ==
      "lan://127.0.0.0/8?tls=1&profile=hardened"
    check withTrustProfile("lan://127.0.0.0/8?tls=1", "") ==
      "lan://127.0.0.0/8?tls=1"
    check parsePeerCache(withTrustProfile("lan://127.0.0.0/8",
      "hardened")).config.trustProfile == tpHardened
    expect ValueError:
      discard withTrustProfile("lan://127.0.0.0/8?profile=trusted", "hardened")
    expect ValueError:
      discard withTrustProfile("lan://127.0.0.0/8", "paranoid")
    # One profile per spec: duplicate `profile=` keys are refused by the
    # parser and by `--trust-profile=`, whichever order and whether or not
    # they agree — never resolved by position.
    check not parsePeerCache(
      "lan://127.0.0.0/8?tls=1&profile=trusted&profile=hardened").ok
    check not parsePeerCache(
      "lan://127.0.0.0/8?profile=hardened&tls=1&profile=trusted").ok
    check not parsePeerCache(
      "lan://127.0.0.0/8?profile=hardened&profile=hardened").ok
    expect ValueError:
      discard withTrustProfile(
        "lan://127.0.0.0/8?profile=trusted&profile=hardened", "trusted")
    expect ValueError:
      discard withTrustProfile(
        "lan://127.0.0.0/8?profile=hardened&profile=hardened", "hardened")
    # `--trust-profile=` given twice on the command line is refused too
    # (the flag loop of `repro build` calls this; rc 2), agreeing or not.
    var seen = false
    check acceptTrustProfileFlag(seen, "hardened") == "hardened"
    expect ValueError:
      discard acceptTrustProfileFlag(seen, "hardened")
    var seenOther = false
    check acceptTrustProfileFlag(seenOther, "trusted") == "trusted"
    expect ValueError:
      discard acceptTrustProfileFlag(seenOther, "hardened")
    check identityPolicyOf(tpTrusted) == ipPinnedHostKey
    check identityPolicyOf(tpHardened) == ipShortLivedLeaves

  test "hardened enables the hardened controls; trusted does not":
    let base = createTempDir("m7-profiles-", "")
    var a = newTestNode(base, "a")
    var b = newTestNode(base, "b")
    mutualTrust([a, b])
    var trustedHost, hardenedHost: PeerCacheHost
    defer:
      if not trustedHost.isNil: trustedHost.stop()
      if not hardenedHost.isNil: hardenedHost.stop()
      removeDir(base)
    trustedHost = startPeerCacheHost(tlsConfig(a, profile = tpTrusted),
      a.identity.hostId, cacheRoot = base / "a-cache")
    let tLeaf = trustedHost.currentLeaf()
    # Trusted: the wire carries the host's OWN long-lived key.
    check tLeaf.cert.keypair.publicKey == a.identity.ca.keypair.publicKey
    check tLeaf.cert.notAfter - tLeaf.cert.notBefore > 30'i64 * 86_400
    check trustedHost.tls.anchors.identityPolicy == ipPinnedHostKey
    hardenedHost = startPeerCacheHost(tlsConfig(b, profile = tpHardened),
      b.identity.hostId, cacheRoot = base / "b-cache")
    let hLeaf = hardenedHost.currentLeaf()
    # Hardened: a fresh key in a host-CA leaf of at most an hour.
    check hLeaf.cert.keypair.publicKey != b.identity.ca.keypair.publicKey
    check hLeaf.cert.notAfter - hLeaf.cert.notBefore <=
      int64(MaxLeafTtlSeconds + LeafClockSkewSeconds)
    check hardenedHost.tls.anchors.identityPolicy == ipShortLivedLeaves
    # The off-host sink: required off loopback in hardened, not in trusted.
    let lan = BindResolution(ok: true, address: "192.0.2.10",
      interfaceName: "lan0", isLoopback: false)
    expect ValueError:
      validateListenerPolicy(tlsConfig(a, profile = tpHardened), lan)
    validateListenerPolicy(tlsConfig(a, profile = tpTrusted), lan)
    # The sink and the signer are hardened controls: a trusted node asked
    # for one refuses to start rather than ignoring it.
    var withSink = tlsConfig(a, evidence = "127.0.0.1:9", profile = tpTrusted)
    expect ValueError:
      discard startPeerCacheHost(withSink, a.identity.hostId,
        cacheRoot = base / "a2-cache")
    var withSigner = tlsConfig(a, profile = tpTrusted)
    withSigner.signerSpec = "127.0.0.1:9"
    expect ValueError:
      discard startPeerCacheHost(withSigner, a.identity.hostId,
        cacheRoot = base / "a3-cache")
    # Lease confinement: hardened refuses macOS and Windows workers.
    when defined(macosx) or defined(windows):
      check leaseConfinementAvailable(hardened = false).ok
      let refused = leaseConfinementAvailable(hardened = true)
      check not refused.ok
      check "hardened" in refused.reason
    else:
      # Linux (decision 4): the trusted profile is never refused for lacking
      # Landlock or the floor; hardened requires both. So hardened ok
      # implies trusted ok, trusted is ok on any host with the namespace
      # layer, and where they differ hardened's refusal names the layer it
      # lacks.
      let t = availableLeaseLayers(hardened = false)
      let h = availableLeaseLayers(hardened = true)
      checkpoint("this host: trusted " & $t & " / hardened " & $h)
      check t.ok                       # namespaces on every Linux test host
      check (not h.ok) or t.ok
      if t.ok and not h.ok:
        check "Landlock" in h.reason or "the floor" in h.reason
    # Every Linux combination, through the decision seam (pure, so it runs
    # on every host): the branch where trusted runs and hardened is refused
    # is exercised whatever this host has.
    for landlock in [false, true]:
      for subids in [false, true]:
        for tools in [false, true]:
          let probe = LinuxLeaseHostProbe(userNamespaces: true,
            pidfdGetfd: true, landlock: landlock, subordinateIds: subids,
            idMappingTools: tools)
          let tr = decideLinuxLeaseLayers(probe, hardened = false)
          let hr = decideLinuxLeaseLayers(probe, hardened = true)
          let complete = landlock and subids and tools
          checkpoint($probe & " -> trusted " & $tr & " / hardened " & $hr)
          check tr.ok                                # never refused
          check llNamespace in tr.layers
          check (llLandlock in tr.layers) == landlock
          check (llFloor in tr.layers) == (subids and tools)
          check hr.ok == complete
          check (not hr.ok) or tr.ok                 # hardened => trusted
          if not complete:
            check not hr.ok
            if not landlock:
              check "Landlock" in hr.reason
            if not (subids and tools):
              check "the floor" in hr.reason
    # Without the namespace layer neither profile runs a worker.
    let noNs = LinuxLeaseHostProbe(userNamespaces: false, pidfdGetfd: true,
      landlock: true, subordinateIds: true, idMappingTools: true)
    check not decideLinuxLeaseLayers(noNs, hardened = false).ok
    # A CPU the launcher has no backend for (32-bit ARM) is refused by its
    # own name, before the kernel probes: there every one of those answers
    # "absent", and reading that as "no user namespaces" sends the operator
    # to a remedy that cannot help.
    let noArch = LinuxLeaseHostProbe(noConfinementBackend: true,
      userNamespaces: false, pidfdGetfd: false, landlock: false,
      subordinateIds: false, idMappingTools: false)
    for hardened in [false, true]:
      let r = decideLinuxLeaseLayers(noArch, hardened)
      check not r.ok
      check "not supported on this architecture" in r.reason
      check "user namespaces" notin r.reason
    check not decideLinuxLeaseLayers(noNs, hardened = true).ok

  test "long-lived keys: pinned peers both ways, an unpinned peer refused":
    let base = createTempDir("m7-pinned-", "")
    var a = newTestNode(base, "a")
    var b = newTestNode(base, "b")
    var c = newTestNode(base, "c")
    mutualTrust([a, b])
    c.trusts(a)                  # C pins A; A does NOT pin C
    var hostA, hostB, hostC, hostC2: PeerCacheHost
    defer:
      for h in [hostC2, hostC, hostB, hostA]:
        if not h.isNil: h.stop()
      removeDir(base)
    hostA = startPeerCacheHost(tlsConfig(a, profile = tpTrusted),
      a.identity.hostId, cacheRoot = base / "a-cache",
      stateDir = base / "a-state")
    let aEnd = initEndpoint("127.0.0.1", hostA.actualPort)
    hostB = startPeerCacheHost(tlsConfig(b, seeds = @[aEnd],
      profile = tpTrusted), b.identity.hostId, cacheRoot = base / "b-cache")
    let aId = a.identity.hostId
    let bId = b.identity.hostId
    let cId = c.identity.hostId
    let d = blob(hostA, "pinned")
    # Positive control: mutual TLS, both pinned — B fetches from A, and A's
    # server authenticated B as B (the client side verified A as A).
    check hostB.client.fetchOk(aId, d)
    check hostB.client.isConnected(aId)
    tickFor([hostA, hostB], 300)
    check hostA.server.inboundAuthenticated[(bId, lrDaemon)] >= 1

    # Server side: C dials A with its own long-lived key, which A has not
    # pinned. Refused at the handshake (TLS validates nothing for it) or at
    # the identity proof — either way C is never A's peer.
    hostC = startPeerCacheHost(tlsConfig(c, seeds = @[aEnd],
      profile = tpTrusted), cId, cacheRoot = base / "c-cache")
    tickFor([hostA, hostC], 500)
    discard waitFor hostC.client.connectKnownPeers()
    check not hostC.client.isConnected(aId)
    check not hostC.client.fetchOk(aId, d)
    check hostA.server.inboundAuthenticated[(cId, lrDaemon)] == 0

    # Client side: A dials C (C pins A, so C would accept A) — but A has not
    # pinned C's key, so A's client refuses the server.
    var aDials = tlsConfig(a, seeds = @[initEndpoint("127.0.0.1",
      hostC.actualPort)], profile = tpTrusted)
    hostC2 = startPeerCacheHost(aDials, aId, cacheRoot = base / "a2-cache")
    tickFor([hostC, hostC2], 500)
    discard waitFor hostC2.client.connectKnownPeers()
    check not hostC2.client.isConnected(cId)

    # A certificate SIGNED by B's pinned host key but carrying a FRESH key
    # (the hardened shape) is not B's pinned key: refused.
    let freshLeaf = mintLeaf(b.identity, lrDaemon)
    let verdict = verifyLeaf(freshLeaf.cert.certDer, hostA.tls.anchors,
      getTime().toUnix)
    check not verdict.ok
    check "unpinned" in verdict.reason
    # …while B's own host-key certificate is accepted (the control).
    let own = mintHostCertificate(b.identity, lrDaemon)
    check verifyLeaf(own.cert.certDer, hostA.tls.anchors, getTime().toUnix).ok

    # Revocation = remove the pin: B's next frame is refused, and a new
    # handshake fails; re-pinned, B is back.
    let pin = a.anchorsDir / "b.crt"
    let saved = readFile(pin)
    removeFile(pin)
    tickFor([hostA], 600)
    check not hostB.client.fetchOk(aId, d)
    tickFor([hostA, hostB], 300)
    discard waitFor hostB.client.connectKnownPeers()
    check not hostB.client.isConnected(aId)
    check not verifyLeaf(own.cert.certDer, hostA.tls.anchors,
      getTime().toUnix).ok
    writeFile(pin, saved)
    tickFor([hostA], 600)
    discard waitFor hostB.client.connectKnownPeers()
    check hostB.client.isConnected(aId)
    check hostB.client.fetchOk(aId, d)
