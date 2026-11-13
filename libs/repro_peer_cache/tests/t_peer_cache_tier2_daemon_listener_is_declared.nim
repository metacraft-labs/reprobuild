## Distributed-Execution M7 (FLOW-6; threat model §7.8): the tier-2 rack
## daemon (`apps/repro-peer-cache-tier2`) binds loopback unless the operator
## names an address, and never a wildcard.
##
##   * the default configuration, and a command line with no `--listen`,
##     listen on `127.0.0.1` — a daemon started bare used to bind `0.0.0.0`,
##     because `defaultConfig` hard-coded it while the `DefaultListen`
##     constant said loopback;
##   * `--listen=<wildcard>:<port>` is refused for every wildcard spelling,
##     while a named address is accepted (the positive control: the parser
##     is not refusing every `--listen`);
##   * a configuration built in code with a wildcard is refused by
##     `bootDaemon` itself, before any socket or store is created.
##
## MOCK POLICY — none: the daemon's own configuration parser and boot
## procedure; nothing is started.

import std/[os, unittest]

import "../../../apps/repro-peer-cache-tier2/repro_peer_cache_tier2"

suite "Distributed-Execution M7: the tier-2 daemon's listener":

  test "the default listener is loopback and a wildcard is refused":
    check defaultConfig().listenHost == "127.0.0.1"
    check parseConfig([]).listenHost == "127.0.0.1"
    let named = parseConfig(["--listen=10.1.2.3:7777"])
    check named.listenHost == "10.1.2.3"
    check int(named.listenPort) == 7777
    for wildcard in ["0.0.0.0", "*", "any"]:
      expect Tier2DaemonError:
        discard parseConfig(["--listen=" & wildcard & ":7777"])
    var forced = defaultConfig()
    forced.listenHost = "0.0.0.0"
    forced.storeDir = getTempDir() / ("repro-tier2-wildcard-" &
      $getCurrentProcessId())
    expect Tier2DaemonError:
      discard bootDaemon(forced, silent = true)
    check not dirExists(forced.storeDir)

## Distributed-Execution M7 review (threat model G27): the tier-2 rack daemon
## is a Boundary node like every other — it authenticates with a host CA and
## short-lived leaves, refuses legacy long-lived certificates, audits every
## frame to an off-host evidence sink (required off loopback), and defaults
## its CIDR allow-list to loopback (an explicit `--cidr` is required off
## loopback). The checks below are on the boot procedure, which builds the
## server and client but starts no socket (the daemon that owns the host CA
## never reaches the wire in this test).

import repro_peer_cache

proc tier2Tls(base: string): tuple[cfg: Tier2DaemonConfig; sinkCert: string] =
  ## A config whose TLS paths point at a freshly minted host CA, with the
  ## sink's CA pinned where the daemon looks for it.
  let tls = base / "tls"
  createDir(tls / "anchors")
  let id = loadOrCreateHostIdentity(tls / "host-ca.crt", tls / "host-ca.key")
  copyFile(tls / "host-ca.crt", tls / "anchors" / "self.crt")
  let sinkId = loadOrCreateHostIdentity(base / "sink" / "host-ca.crt",
    base / "sink" / "host-ca.key")
  result.sinkCert = tls / "evidence-sink.crt"
  copyFile(base / "sink" / "host-ca.crt", result.sinkCert)
  result.cfg = defaultConfig()
  result.cfg.tlsCertPath = tls / "host-ca.crt"
  result.cfg.tlsKeyPath = tls / "host-ca.key"
  result.cfg.tlsTrustAnchorsPath = tls / "anchors"
  result.cfg.storeDir = base / "store"
  result.cfg.peerIdPath = base / "store" / "peer-id"
  discard sinkId

suite "Distributed-Execution M7: the tier-2 daemon is a Boundary node (G27)":

  test "it requires TLS, short-lived leaves, a sink off loopback, and a named CIDR":
    let base = getTempDir() / ("repro-tier2-g27-" & $getCurrentProcessId())
    removeDir(base)
    defer: removeDir(base)

    # Without any TLS material: refused (CIDR-only trust is gone).
    var noTls = defaultConfig()
    noTls.tlsCertPath = base / "absent.crt"
    noTls.tlsKeyPath = base / "absent.key"
    noTls.tlsTrustAnchorsPath = base / "absent-anchors"
    noTls.storeDir = base / "s0"
    expect Tier2DaemonError:
      discard bootDaemon(noTls, silent = true)

    # Loopback with TLS: boots. Its node is its host CA's id, it requires
    # short-lived leaves, and its gate carries an audit sink.
    let (loop, _) = tier2Tls(base / "loop")
    let d = bootDaemon(loop, silent = true)
    check d.selfPeerId == d.identity.hostId
    check d.server.requireShortLivedLeaves
    check d.server.trustMode == tmTls
    check not d.server.gate.audit.isNil
    check not d.leaf.key.isNil

    # The default allow-list is loopback, never 0.0.0.0/0.
    check defaultConfig().cidrs == @["127.0.0.0/8"]
    check not defaultConfig().explicitCidr

    # Off loopback without a declared CIDR: refused.
    var (noCidr, _) = tier2Tls(base / "nocidr")
    noCidr.listenHost = "10.9.8.7"
    expect Tier2DaemonError:
      discard bootDaemon(noCidr, silent = true)

    # Off loopback with a CIDR but no evidence sink: refused.
    var (noSink, _) = tier2Tls(base / "nosink")
    noSink.listenHost = "10.9.8.7"
    noSink.cidrs = @["10.9.0.0/16"]
    noSink.explicitCidr = true
    expect Tier2DaemonError:
      discard bootDaemon(noSink, silent = true)

    # Off loopback, a CIDR and a pinned sink: boots, appender pinned.
    var (full, sinkCert) = tier2Tls(base / "full")
    full.listenHost = "10.9.8.7"
    full.cidrs = @["10.9.0.0/16"]
    full.explicitCidr = true
    full.evidenceSpec = "10.9.0.10:7900"
    full.evidenceCaPath = sinkCert
    let d2 = bootDaemon(full, silent = true)
    check not d2.appender.isNil
