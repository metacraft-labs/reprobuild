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
    check r.config.tlsCertPath ==
      "/tmp/m4_cli_xdg_test/repro-peer-cache/tls/peer.crt"
    check r.config.tlsKeyPath ==
      "/tmp/m4_cli_xdg_test/repro-peer-cache/tls/peer.key"
    check r.config.tlsTrustAnchorsPath ==
      "/tmp/m4_cli_xdg_test/repro-peer-cache/tls/anchors"

  test "no query knob leaves trustMode at the default":
    let r = parsePeerCache("lan://127.0.0.0/8:17654")
    check r.ok
    check r.kind == pcsLan
    check r.config.trustMode == tmCidr
    check r.config.tlsCertPath == ""

  test "unrecognised query knob is rejected":
    let r = parsePeerCache("lan://127.0.0.0/8:17654?foo=bar")
    check (not r.ok)
