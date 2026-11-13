## Peer-Cache-BearSSL M4: `?tls=1` query knob on the `--peer-cache=lan://`
## CLI surface flips the trust mode to `tmTls` and populates the
## XDG-default TLS paths.

import std/[os, strutils, unittest]

import repro_cli_support
import repro_peer_cache

{.used.}

suite "peer-cache CLI lan:// ?tls=1 query knob (M4)":
  test "tls=1 sets trustMode=tmTls and TLS paths under XDG_STATE_HOME":
    putEnv("XDG_STATE_HOME", "/tmp/m4_cli_xdg_test")
    let r = parsePeerCache("lan://127.0.0.0/8:17654?tls=1")
    check r.ok
    check r.kind == pcsLan
    check r.config.trustMode == tmTls
    # Distributed-Execution M7: the persistent credential is the HOST CA
    # (`identity.nim`); the wire carries short-lived leaves it mints.
    check r.config.tlsCertPath ==
      "/tmp/m4_cli_xdg_test/repro-peer-cache/tls/host-ca.crt"
    check r.config.tlsKeyPath ==
      "/tmp/m4_cli_xdg_test/repro-peer-cache/tls/host-ca.key"
    check r.config.tlsTrustAnchorsPath ==
      "/tmp/m4_cli_xdg_test/repro-peer-cache/tls/anchors"

  test "no query knob still yields a TLS node; tls=0 is refused":
    # Distributed-Execution M7 removed CIDR-only trust (deviation D3): a
    # spec without `tls=1` configures the same host-CA paths, and asking
    # for CIDR trust explicitly is a parse error rather than a silent
    # downgrade.
    let r = parsePeerCache("lan://127.0.0.0/8:17654")
    check r.ok
    check r.kind == pcsLan
    check r.config.trustMode == tmTls
    check r.config.tlsCertPath.endsWith("repro-peer-cache/tls/host-ca.crt")
    check not parsePeerCache("lan://127.0.0.0/8:17654?tls=0").ok
    check not parsePeerCache("lan://127.0.0.0/8?multicast=0&tls=0").ok

  test "M7 knobs: a declared interface, never a wildcard; multicast opt-in":
    let declared = parsePeerCache(
      "lan://127.0.0.0/8?tls=1&bind=lo0&evidence=127.0.0.1:9&worker=1")
    check declared.ok
    check declared.config.bindSpec == "lo0"
    check declared.config.evidenceSinkSpec == "127.0.0.1:9"
    check declared.config.workerEnabled
    for wildcard in ["0.0.0.0", "::", "*", "any"]:
      check not parsePeerCache("lan://127.0.0.0/8?bind=" & wildcard).ok
    check parsePeerCache("lan://127.0.0.0/8").config.multicastDisabled
    check not parsePeerCache(
      "lan://127.0.0.0/8?multicast=1").config.multicastDisabled

  test "unrecognised query knob is rejected":
    let r = parsePeerCache("lan://127.0.0.0/8:17654?foo=bar")
    check (not r.ok)
