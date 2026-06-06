# repro_peer_cache

Peer-cache plane for Reprobuild — a LAN-fabric extension of the local
content-addressed action cache. Implements the wire protocol described in
[`reprobuild-specs/Peer-Cache.md`](../../../reprobuild-specs/Peer-Cache.md).

## Status

**M0** — protocol library + unicast loopback discovery. The wire codec,
in-memory peer registry, TCP server, TCP client, and a loopback-spawn
helper for tests. The fetch protocol (`mkFetchRequest` /
`mkFetchResponse`) is **parsed and serialised** but not yet wired to a
content store; that arrives in **M1**.

## Submodules

| Module | Purpose |
|---|---|
| `repro_peer_cache/types` | `PeerId`, `BlobDigest`, `Endpoint`, `MessageKind`, SSZ-shaped record types. |
| `repro_peer_cache/codec` | Frame encode/decode + per-message encoders/decoders + `dispatch`. |
| `repro_peer_cache/registry` | In-memory `PeerRegistry` (advertise snapshot vs delta, suspect, find-by-blob). |
| `repro_peer_cache/server` | `asyncnet` TCP server, handshake handler, advertisement responder, CIDR allowlist. |
| `repro_peer_cache/client` | `asyncnet` TCP dialer, handshake initiator, advertisement publisher. |
| `repro_peer_cache/loopback` | Convenience helpers for spawning N peers on distinct loopback ports (tests + smoke). |

The umbrella module `repro_peer_cache` re-exports all of the above.

## Codec

Frames follow the spec's shape exactly:

```
struct Frame {
  uint16 version;       // current = 1
  uint16 messageKind;   // MessageKind enum tag
  uint32 payloadLen;    // bytes that follow
  bytes  payload[payloadLen];
}
```

Per-message payloads use the same hand-rolled little-endian SSZ-style
encoder pattern as `runquota_codec` — fixed-shape records with explicit
length prefixes for variable-length sequences. The shape matches the
RunQuota envelope convention without taking a hard dependency on the
`ssz-serialization` library; messages are small and fixed, so a
hand-rolled encoder ships less code than the macro-driven path and
remains debuggable byte-for-byte.

## Transport

TCP via `std/asyncnet` + `std/asyncdispatch`. One `PeerCacheServer` per
node listens on a configurable bind address; one `PeerCacheClient`
manages outgoing connections to known peers (seeded explicitly for M0;
multicast discovery lands in M2).

## CIDR allowlist

For M0, the loopback workflow uses `127.0.0.0/8`. The allowlist is
checked against the remote network address from `accept` (not the
`Hello`-announced endpoint). A small `inCidr(ip, cidr)` helper handles
IPv4 prefix matching via integer-mask comparison.

## Tests

Run from the repo root via `just test`. The five M0 verification tests
live in `tests/`:

- `t_peer_cache_codec_frame_round_trip`
- `t_peer_cache_codec_version_mismatch_rejected`
- `t_peer_cache_registry_advertise_snapshot_and_delta`
- `t_peer_cache_loopback_three_peer_discovery`
- `t_peer_cache_handshake_rejects_unknown_peer_id`
